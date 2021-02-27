/*
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */

/*
 *  Emulate vm86() using KVM
 *  Started 2015, Bart Oldeman
 *  References: http://lwn.net/Articles/658511/
 *  plus example at http://lwn.net/Articles/658512/
 */

#ifdef __linux__
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/kvm.h>

#include "kvm.h"
#include "emu.h"
#include "emu-ldt.h"
#include "cpu-emu.h"
#include "vgaemu.h"
#include "mapping.h"
#include "sig.h"

#ifndef X86_EFLAGS_FIXED
#define X86_EFLAGS_FIXED 2
#endif
#include "dpmi.h"

#define SAFE_MASK (X86_EFLAGS_CF|X86_EFLAGS_PF| \
                   X86_EFLAGS_AF|X86_EFLAGS_ZF|X86_EFLAGS_SF| \
                   X86_EFLAGS_TF|X86_EFLAGS_DF|X86_EFLAGS_OF| \
                   X86_EFLAGS_RF| \
                   X86_EFLAGS_NT|X86_EFLAGS_AC|X86_EFLAGS_ID) // 0x254dd5
#define RETURN_MASK ((SAFE_MASK | 0x28 | X86_EFLAGS_FIXED) & \
                     ~X86_EFLAGS_RF) // 0x244dff

extern char kvm_mon_start[];
extern char kvm_mon_hlt[];
extern char kvm_mon_end[];

/* V86/DPMI monitor structure to run code in V86 mode with VME enabled
   or DPMI clients inside KVM
   This contains:
   1. a TSS with
     a. ss0:esp0 set to a stack at the top of the monitor structure
        This stack contains a copy of the vm86_regs struct.
     b. An interrupt redirect bitmap copied from info->int_revectored
     c. I/O bitmap, for now set to trap all ints. Todo: sync with ioperm()
   2. A GDT with 3 entries
     a. 0 entry
     b. selector 8: flat CS
     c. selector 0x10: based SS (so the high bits of ESP are always 0,
        which avoids issues with IRET).
   3. An IDT with 256 (0x100) entries:
     a. 0x11 entries for CPU exceptions that can occur
     b. 0xef entries for software interrupts
   4. The stack (from 1a) above
   5. Page directory and page tables
   6. The LDT, used by DPMI code; ldt_buffer in dpmi.c points here
   7. The code pointed to by the IDT entries, from kvmmon.S, on a new page
      This just pushes the exception number, error code, and all registers
      to the stack and executes the HLT instruction which is then trapped
      by KVM.
 */

#define TSS_IOPB_SIZE (65536 / 8)
#define GDT_ENTRIES 3
#undef IDT_ENTRIES
#define IDT_ENTRIES 0x100

#define PG_PRESENT 1
#define PG_RW 2
#define PG_USER 4

static struct monitor {
    Task tss;                                /* 0000 */
    /* tss.esp0                                 0004 */
    /* tss.ss0                                  0008 */
    /* tss.IOmapbaseT (word)                    0066 */
    struct revectored_struct int_revectored; /* 0068 */
    unsigned char io_bitmap[TSS_IOPB_SIZE+1];/* 0088 */
    /* TSS last byte (limit)                    2088 */
    unsigned char padding0[0x2100-sizeof(Task)
		-sizeof(struct revectored_struct)
		-(TSS_IOPB_SIZE+1)];
    Descriptor gdt[GDT_ENTRIES];             /* 2100 */
    unsigned char padding1[0x2200-0x2100
	-GDT_ENTRIES*sizeof(Descriptor)];    /* 2118 */
    Gatedesc idt[IDT_ENTRIES];               /* 2200 */
    unsigned char padding2[0x3000-0x2200
	-IDT_ENTRIES*sizeof(Gatedesc)
	-sizeof(unsigned int)
	-sizeof(struct vm86_regs)];          /* 2308 */
    unsigned int cr2;         /* Fault stack at 2FA8 */
    struct vm86_regs regs;
    /* 3000: page directory, 4000: page table */
    unsigned int pde[PAGE_SIZE/sizeof(unsigned int)];
    unsigned int pte[(PAGE_SIZE*PAGE_SIZE)/sizeof(unsigned int)
		     /sizeof(unsigned int)];
    Descriptor ldt[LDT_ENTRIES];             /* 404000 */
    unsigned char code[256 * 32 + PAGE_SIZE];         /* 414000 */
    /* 414000 IDT exception 0 code start
       414010 IDT exception 1 code start
       .... ....
       414ff0 IDT exception 0xff code start
       415000 IDT common code start
       415024 IDT common code end
    */
    unsigned char kvm_tss[3*PAGE_SIZE];
    unsigned char kvm_identity_map[20*PAGE_SIZE];
} *monitor;

static struct kvm_cpuid2 *cpuid;
/* fpu vme de pse tsc msr mce cx8 */
#define CPUID_FEATURES_EDX 0x1bf
static struct kvm_run *run;
static int kvmfd, vmfd, vcpufd;
static volatile int mprotected_kvm = 0;
static struct kvm_sregs sregs;

#define MAXSLOT 400
static struct kvm_userspace_memory_region maps[MAXSLOT];

static int init_kvm_vcpu(void);

static void set_idt_default(dosaddr_t mon, int i)
{
    unsigned int offs = mon + offsetof(struct monitor, code) + i * 32;
    monitor->idt[i].offs_lo = offs & 0xffff;
    monitor->idt[i].offs_hi = offs >> 16;
    monitor->idt[i].seg = 0x8; // FLAT_CODE_SEL
    monitor->idt[i].type = 0xe;
    /* DPL is 0 so that software ints < 0x11 or 255 from DPMI clients will GPF.
       Exceptions are int3 (BP) and into (OF): matching the Linux kernel
       they must generate traps 3 and 4, and not GPF.
       Exceptions > 0x10 cannot be triggered with the VM's settings of CR0/CR4
       Exception 0x10 is special as it is also a common software int; in real
       DOS it can be turned off by resetting cr0.ne so it triggers IRQ13
       directly but this is impossible with KVM */
    monitor->idt[i].DPL = (i == 3 || i == 4 || i > 0x10) ? 3 : 0;
}

void kvm_set_idt_default(int i)
{
    if (i < 0x11)
        return;
    set_idt_default(DOSADDR_REL((unsigned char *)monitor), i);
}

static void set_idt(int i, uint16_t sel, uint32_t offs, int is_32, int tg)
{
    monitor->idt[i].offs_lo = offs & 0xffff;
    monitor->idt[i].offs_hi = offs >> 16;
    monitor->idt[i].seg = sel;
    monitor->idt[i].type = is_32 ? 0xe : 0x6;
    if (tg)
        monitor->idt[i].type |= 1;
    monitor->idt[i].DPL = 3;
}

void kvm_set_idt(int i, uint16_t sel, uint32_t offs, int is_32, int tg)
{
    /* don't change IDT for exceptions and special entry that interrupts
       the VM */
    if (i < 0x11)
        return;
    set_idt(i, sel, offs, is_32, tg);
}

/* initialize KVM virtual machine monitor */
void init_kvm_monitor(void)
{
  int ret, i;

  /* create monitor structure in memory */
  monitor = mmap_mapping_ux(MAPPING_SCRATCH | MAPPING_KVM, (void *)-1,
			    sizeof(*monitor), PROT_READ | PROT_WRITE);
  /* trap all I/O instructions with GPF */
  memset(monitor->io_bitmap, 0xff, TSS_IOPB_SIZE+1);

  if (!init_kvm_vcpu()) {
    leavedos(99);
    return;
  }

  ret = ioctl(vcpufd, KVM_GET_SREGS, &sregs);
  if (ret == -1) {
    perror("KVM: KVM_GET_SREGS");
    leavedos(99);
    return;
  }

  sregs.tr.base = DOSADDR_REL((unsigned char *)monitor);
  sregs.tr.limit = offsetof(struct monitor, io_bitmap) + TSS_IOPB_SIZE;
  sregs.tr.unusable = 0;
  sregs.tr.type = 0xb;
  sregs.tr.s = 0;
  sregs.tr.dpl = 0;
  sregs.tr.present = 1;
  sregs.tr.avl = 0;
  sregs.tr.l = 0;
  sregs.tr.db = 0;
  sregs.tr.g = 0;

#ifdef X86_EMULATOR
  LDT = monitor->ldt;
#endif
  ldt_buffer = (unsigned char *)monitor->ldt;
  sregs.ldt.base = sregs.tr.base + offsetof(struct monitor, ldt);
  sregs.ldt.limit = LDT_ENTRIES * LDT_ENTRY_SIZE - 1;
  sregs.ldt.unusable = 0;
  sregs.ldt.type = 0x2;
  sregs.ldt.s = 0;
  sregs.ldt.dpl = 0;
  sregs.ldt.present = 1;
  sregs.ldt.avl = 0;
  sregs.ldt.l = 0;
  sregs.ldt.db = 0;
  sregs.ldt.g = 0;

  monitor->tss.ss0 = 0x10;
  monitor->tss.IOmapbase = offsetof(struct monitor, io_bitmap);

  // setup GDT
  sregs.gdt.base = sregs.tr.base + offsetof(struct monitor, gdt);
  sregs.gdt.limit = GDT_ENTRIES * sizeof(Descriptor) - 1;
  for (i=1; i<GDT_ENTRIES; i++) {
    monitor->gdt[i].limit_lo = 0xffff;
    monitor->gdt[i].type = 0xa;
    monitor->gdt[i].S = 1;
    monitor->gdt[i].present = 1;
    monitor->gdt[i].limit_hi = 0xf;
    monitor->gdt[i].DB = 1;
    monitor->gdt[i].gran = 1;
  }
  // based data selector (0x10), to avoid the ESP register corruption bug
  monitor->gdt[GDT_ENTRIES-1].type = 2;
  MKBASE(&monitor->gdt[GDT_ENTRIES-1], sregs.tr.base);

  sregs.idt.base = sregs.tr.base + offsetof(struct monitor, idt);
  sregs.idt.limit = IDT_ENTRIES * sizeof(Gatedesc)-1;
  // setup IDT
  for (i=0; i<IDT_ENTRIES; i++) {
    set_idt_default(sregs.tr.base, i);
    monitor->idt[i].present = 1;
  }
  assert(kvm_mon_end - kvm_mon_start <= sizeof(monitor->code));
  memcpy(monitor->code, kvm_mon_start, kvm_mon_end - kvm_mon_start);

  /* setup paging */
  sregs.cr3 = sregs.tr.base + offsetof(struct monitor, pde);
  /* base PDE; others derive from this one */
  monitor->pde[0] = (sregs.tr.base + offsetof(struct monitor, pte))
    | (PG_PRESENT | PG_RW | PG_USER);
  mprotect_kvm(MAPPING_KVM, sregs.tr.base, offsetof(struct monitor, code),
	       PROT_READ | PROT_WRITE);
  mprotect_kvm(MAPPING_KVM, sregs.tr.base + offsetof(struct monitor, code),
	       sizeof(monitor->code), PROT_READ | PROT_EXEC);

  sregs.cr0 |= X86_CR0_PE | X86_CR0_PG | X86_CR0_NE | X86_CR0_ET;
  sregs.cr4 |= X86_CR4_VME;

  /* setup registers to point to VM86 monitor */
  sregs.cs.base = 0;
  sregs.cs.limit = 0xffffffff;
  sregs.cs.selector = 0x8;
  sregs.cs.db = 1;
  sregs.cs.g = 1;

  sregs.ss.base = sregs.tr.base;
  sregs.ss.limit = 0xffffffff;
  sregs.ss.selector = 0x10;
  sregs.ss.db = 1;
  sregs.ss.g = 1;

  if (config.cpu_vm == CPUVM_KVM)
    warn("Using V86 mode inside KVM\n");
}

/* Initialize KVM and memory mappings */
static int init_kvm_vcpu(void)
{
  int ret, mmap_size;

#ifdef KVM_CAP_SYNC_REGS
  ret = ioctl(kvmfd, KVM_CHECK_EXTENSION, KVM_CAP_SYNC_REGS);
  if (ret == -1 || (ret & KVM_SYNC_X86_VALID_FIELDS) !=
      KVM_SYNC_X86_VALID_FIELDS) {
    error("KVM: CHECK_EXTENSION(SYNC_REGS) returned %x\n", ret);
    return 0;
  }
#else
  error("kernel is too old, KVM unsupported\n");
  return 0;
#endif

  /* this call is only there to shut up the kernel saying
     "KVM_SET_TSS_ADDR need to be called before entering vcpu"
     this is only really needed if the vcpu is started in real mode and
     the kernel needs to emulate that using V86 mode, as is necessary
     on Nehalem and earlier Intel CPUs */
  ret = ioctl(vmfd, KVM_SET_TSS_ADDR,
	      (unsigned long)DOSADDR_REL(monitor->kvm_tss));
  if (ret == -1) {
    perror("KVM: KVM_SET_TSS_ADDR\n");
    return 0;
  }

  uint64_t addr = DOSADDR_REL(monitor->kvm_identity_map);
  ret = ioctl(vmfd, KVM_SET_IDENTITY_MAP_ADDR, &addr);
  if (ret == -1) {
    perror("KVM: KVM_SET_IDENTITY_MAP_ADDR\n");
    return 0;
  }

  vcpufd = ioctl(vmfd, KVM_CREATE_VCPU, (unsigned long)0);
  if (vcpufd == -1) {
    perror("KVM: KVM_CREATE_VCPU");
    return 0;
  }

  assert(cpuid);
  // Use the same values as in emu-i386/simx86/interp.c
  // (Pentium 133-200MHz, "GenuineIntel")
  cpuid->entries[0].eax = 1;
  cpuid->entries[0].ebx = 0x756e6547;
  cpuid->entries[0].ecx = 0x6c65746e;
  cpuid->entries[0].edx = 0x49656e69;
  // family 5, model 2, stepping 12, features see above
  cpuid->entries[1].eax = 0x052c;
  cpuid->entries[1].ebx = 0;
  cpuid->entries[1].ecx = 0;
  cpuid->entries[1].edx = CPUID_FEATURES_EDX;
  ret = ioctl(vcpufd, KVM_SET_CPUID2, cpuid);
  if (ret == -1) {
    perror("KVM: KVM_SET_CPUID2");
    return 0;
  }

  mmap_size = ioctl(kvmfd, KVM_GET_VCPU_MMAP_SIZE, NULL);
  if (mmap_size == -1) {
    perror("KVM: KVM_GET_VCPU_MMAP_SIZE");
    return 0;
  }
  if (mmap_size < sizeof(*run)) {
    error("KVM: KVM_GET_VCPU_MMAP_SIZE unexpectedly small\n");
    return 0;
  }
  run = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpufd, 0);
  if (run == MAP_FAILED) {
    perror("KVM: mmap vcpu");
    return 0;
  }
  run->exit_reason = KVM_EXIT_INTR;
  return 1;
}

int init_kvm_cpu(void)
{
  int ret;
  int nent = 512;

  kvmfd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
  if (kvmfd == -1) {
    error("KVM: error opening /dev/kvm: %s\n", strerror(errno));
    return 0;
  }

  vmfd = ioctl(kvmfd, KVM_CREATE_VM, (unsigned long)0);
  if (vmfd == -1) {
    warn("KVM: KVM_CREATE_VM: %s\n", strerror(errno));
    return 0;
  }

  cpuid = malloc(sizeof(*cpuid) + nent * sizeof(cpuid->entries[0]));
  memset(cpuid, 0, sizeof(*cpuid) + nent * sizeof(cpuid->entries[0]));	// valgrind
  cpuid->nent = nent;
  ret = ioctl(kvmfd, KVM_GET_SUPPORTED_CPUID, cpuid);
  if (ret == -1) {
    perror("KVM: KVM_GET_SUPPORTED_CPUID");
    goto err;
  }
  if ((cpuid->entries[1].edx & CPUID_FEATURES_EDX) != CPUID_FEATURES_EDX) {
    error("KVM: unsupported features, need %x got %x\n",
        CPUID_FEATURES_EDX, cpuid->entries[1].edx);
    goto err;
  }

  return 1;

err:
  free(cpuid);
  cpuid = NULL;
  return 0;
}

static void set_kvm_memory_region(struct kvm_userspace_memory_region *region)
{
  int ret = ioctl(vmfd, KVM_SET_USER_MEMORY_REGION, region);
  if (ret == -1) {
    perror("KVM: KVM_SET_USER_MEMORY_REGION");
    leavedos_main(99);
  }
}

void set_kvm_memory_regions(void)
{
  int slot;
  for (slot = 0; slot < MAXSLOT; slot++) {
    struct kvm_userspace_memory_region *p = &maps[slot];
    if (p->memory_size != 0) {
      if (config.cpu_vm_dpmi != CPUVM_KVM &&
	  (void *)(uintptr_t)p->userspace_addr != monitor) {
	if (p->guest_phys_addr > LOWMEM_SIZE + HMASIZE)
	  p->memory_size = 0;
	else if (p->guest_phys_addr + p->memory_size > LOWMEM_SIZE + HMASIZE)
	  p->memory_size = LOWMEM_SIZE + HMASIZE - p->guest_phys_addr;
      }
    }
    if (p->memory_size != 0)
      set_kvm_memory_region(p);
  }
}

static int mmap_kvm_no_overlap(unsigned targ, void *addr, size_t mapsize)
{
  struct kvm_userspace_memory_region *region;
  int slot;

  for (slot = 0; slot < MAXSLOT; slot++)
    if (maps[slot].memory_size == 0) break;

  if (slot == MAXSLOT) {
    error("KVM: insufficient number of memory slots %i\n", MAXSLOT);
    leavedos_main(99);
  }

  region = &maps[slot];
  region->slot = slot;
  /* NOTE: KVM guest does not have the mem_base offset in LDT
   * because we can do the same with EPT, keeping guest mem zero-based. */
  region->guest_phys_addr = targ;
  region->userspace_addr = (uintptr_t)addr;
  region->memory_size = mapsize;
  Q_printf("KVM: mapped guest %#x to host addr %p, size=%zx\n",
	   targ, addr, mapsize);
  return slot;
}

static void check_overlap_kvm(dosaddr_t targ, size_t mapsize)
{
  /* unmaps KVM regions from targ to targ+mapsize, taking care of overlaps */
  int slot;
  for (slot = 0; slot < MAXSLOT; slot++) {
    struct kvm_userspace_memory_region *region = &maps[slot];
    size_t sz = region->memory_size;
    unsigned gpa = region->guest_phys_addr;
    if (sz > 0 && targ + mapsize > gpa && targ < gpa + sz) {
      error("KVM: mapping inconsistency\n");
      leavedos(99);
    }
  }
}

static void do_munmap_kvm(dosaddr_t targ, size_t mapsize)
{
  /* unmaps KVM regions from targ to targ+mapsize, taking care of overlaps */
  int slot;
  for (slot = 0; slot < MAXSLOT; slot++) {
    struct kvm_userspace_memory_region *region = &maps[slot];
    size_t sz = region->memory_size;
    unsigned gpa = region->guest_phys_addr;
    if (sz > 0 && targ + mapsize > gpa && targ < gpa + sz) {
      /* overlap: first  unmap this mapping */
      region->memory_size = 0;
      set_kvm_memory_region(region);
      /* may need to remap head or tail */
      if (gpa < targ) {
	region->memory_size = targ - gpa;
	set_kvm_memory_region(region);
      }
      if (gpa + sz > targ + mapsize) {
	int slot2 = mmap_kvm_no_overlap(targ + mapsize,
			    (void *)((uintptr_t)region->userspace_addr +
				     targ + mapsize - gpa),
			    gpa + sz - (targ + mapsize));
	set_kvm_memory_region(&maps[slot2]);
      }
    }
  }
}

void munmap_kvm(int cap, dosaddr_t targ, size_t mapsize)
{
  if (cap & MAPPING_IMMEDIATE)
    do_munmap_kvm(targ, mapsize);
  else
    check_overlap_kvm(targ, mapsize);
}

void mmap_kvm(int cap, void *addr, size_t mapsize, int protect)
{
  dosaddr_t targ;
  int slot;

  if (cap == (MAPPING_DPMI|MAPPING_SCRATCH)) {
    mprotect_kvm(cap, DOSADDR_REL(addr), mapsize, protect);
    return;
  }
  if (!(cap & (MAPPING_INIT_LOWRAM|MAPPING_VGAEMU|MAPPING_KMEM|MAPPING_KVM|
      MAPPING_IMMEDIATE)))
    return;
  if (cap & MAPPING_INIT_LOWRAM) {
    targ = 0;
  }
  else {
    targ = DOSADDR_REL(addr);
    if (cap & MAPPING_KVM) {
      /* exclude special regions for KVM-internal TSS and identity page */
      mapsize = offsetof(struct monitor, kvm_tss);
    }
  }
  /* with KVM we need to manually remove/shrink existing mappings */
  if (cap & MAPPING_IMMEDIATE)
    do_munmap_kvm(targ, mapsize);
  else
    check_overlap_kvm(targ, mapsize);
  slot = mmap_kvm_no_overlap(targ, addr, mapsize);
  mprotect_kvm(cap, targ, mapsize, protect);
  /* update EPT if needed */
  if (cap & MAPPING_IMMEDIATE)
    set_kvm_memory_region(&maps[slot]);
}

void mprotect_kvm(int cap, dosaddr_t targ, size_t mapsize, int protect)
{
  size_t pagesize = sysconf(_SC_PAGESIZE);
  unsigned int start = targ / pagesize;
  unsigned int end = start + mapsize / pagesize;
  unsigned int page;

  if (!(cap & (MAPPING_INIT_LOWRAM|MAPPING_LOWMEM|MAPPING_EMS|MAPPING_HMA|
	       MAPPING_DPMI|MAPPING_VGAEMU|MAPPING_KVM|MAPPING_CPUEMU))) return;

  if (monitor == NULL) return;

  Q_printf("KVM: protecting %x:%zx with prot %x\n", targ, mapsize, protect);

  for (page = start; page < end; page++) {
    int pde_entry = page >> 10;
    if (monitor->pde[pde_entry] == 0)
      monitor->pde[pde_entry] = monitor->pde[0] + pde_entry*pagesize;
    monitor->pte[page] = page * pagesize;
    if (protect & PROT_WRITE)
      monitor->pte[page] |= PG_PRESENT | PG_RW | PG_USER;
    else if (protect & PROT_READ)
      monitor->pte[page] |= PG_PRESENT | PG_USER;
    if (cap & MAPPING_KVM)
      monitor->pte[page] &= ~PG_USER;
  }

  mprotected_kvm = 1;
}

/* This function works like handle_vm86_fault in the Linux kernel,
   except:
   * since we use VME we only need to handle
     PUSHFD, POPFD, IRETD always
     POPF, IRET only if it sets TF or IF with VIP set
     STI only if VIP is set and VIF was not set
     INT only if it is revectored
   * The Linux kernel splits the CPU flags into on-CPU flags and
     flags (VFLAGS) IOPL, NT, AC, and ID that are kept on the stack.
     Here all those flags are merged into on-CPU flags, with the
     exception of IOPL. IOPL is always set to 0 on the CPU,
     and to 3 on the stack with PUSHF
*/
static int kvm_handle_vm86_fault(struct vm86_regs *regs, unsigned int cpu_type)
{
  unsigned char opcode;
  int data32 = 0, pref_done = 0;
  unsigned int csp = regs->cs << 4;
  unsigned int ssp = regs->ss << 4;
  unsigned short ip = regs->eip & 0xffff;
  unsigned short sp = regs->esp & 0xffff;
  unsigned int orig_flags = regs->eflags;
  int ret = -1;

  do {
    switch (opcode = popb(csp, ip)) {
    case 0x66:      /* 32-bit data */     data32 = 1; break;
    case 0x67:      /* 32-bit address */  break;
    case 0x2e:      /* CS */              break;
    case 0x3e:      /* DS */              break;
    case 0x26:      /* ES */              break;
    case 0x36:      /* SS */              break;
    case 0x65:      /* GS */              break;
    case 0x64:      /* FS */              break;
    case 0xf2:      /* repnz */           break;
    case 0xf3:      /* rep */             break;
    default: pref_done = 1;
    }
  } while (!pref_done);

  switch (opcode) {

  case 0x9c: { /* only pushfd faults with VME */
    unsigned int flags = regs->eflags & RETURN_MASK;
    if (regs->eflags & X86_EFLAGS_VIF)
      flags |= X86_EFLAGS_IF;
    flags |= X86_EFLAGS_IOPL;
    if (data32)
      pushl(ssp, sp, flags);
    else
      pushw(ssp, sp, flags);
    break;
  }

  case 0xcd: { /* int xx */
    int intno = popb(csp, ip);
    ret = VM86_INTx + (intno << 8);
    break;
  }

  case 0xcf: /* iret */
    if (data32) {
      ip = popl(ssp, sp);
      regs->cs = popl(ssp, sp);
    } else {
      ip = popw(ssp, sp);
      regs->cs = popw(ssp, sp);
    }
    /* fall through into popf */
  case 0x9d: { /* popf */
    unsigned int newflags;
    if (data32) {
      newflags = popl(ssp, sp);
      if (cpu_type >= CPU_286 && cpu_type <= CPU_486) {
	newflags &= ~X86_EFLAGS_ID;
	if (cpu_type < CPU_486)
	  newflags &= ~X86_EFLAGS_AC;
      }
      regs->eflags &= ~SAFE_MASK;
    } else {
      /* must have VIP or TF set in VME, otherwise does not trap */
      newflags = popw(ssp, sp);
      regs->eflags &= ~(SAFE_MASK & 0xffff);
    }
    regs->eflags |= newflags & SAFE_MASK;
    if (newflags & X86_EFLAGS_IF) {
      regs->eflags |= X86_EFLAGS_VIF;
      if (!(orig_flags & X86_EFLAGS_TF) && (orig_flags & X86_EFLAGS_VIP))
        ret = VM86_STI;
    } else {
      regs->eflags &= ~X86_EFLAGS_VIF;
    }
    break;
  }

  case 0xfa: /* CLI (non-VME) */
    regs->eflags &= ~X86_EFLAGS_VIF;
    break;

  case 0xfb: /* STI */
    /* must have VIP set in VME, otherwise does not trap */
    regs->eflags |= X86_EFLAGS_VIF;
    ret = VM86_STI;
    break;

  default:
    return VM86_UNKNOWN;
  }

  regs->esp = (regs->esp & 0xffff0000) | sp;
  regs->eip = (regs->eip & 0xffff0000) | ip;
  if (ret != -1)
    return ret;
  if (orig_flags & X86_EFLAGS_TF)
    return VM86_TRAP + (1 << 8);
  return ret;
}

static void set_vm86_seg(struct kvm_segment *seg, unsigned selector)
{
  seg->selector = selector;
  seg->base = selector << 4;
  seg->limit = 0xffff;
  seg->type = 3;
  seg->present = 1;
  seg->dpl = 3;
  seg->db = 0;
  seg->s = 1;
  seg->g = 0;
  seg->avl = 0;
  seg->unusable = 0;
}

static void set_ldt_seg(struct kvm_segment *seg, unsigned selector)
{
  Descriptor *desc = &monitor->ldt[selector >> 3];
  seg->selector = selector;
  seg->base = DT_BASE(desc);
  seg->limit = DT_LIMIT(desc);
  if (desc->gran) seg->limit = (seg->limit << 12) | 0xfff;
  seg->type = desc->type;
  seg->present = desc->present;
  seg->dpl = desc->DPL;
  seg->db = desc->DB;
  seg->s = desc->S;
  seg->g = desc->gran;
  seg->avl = desc->AVL;
  seg->unusable = !desc->present;
}

static int kvm_post_run(struct vm86_regs *regs)
{
  struct kvm_regs *kregs = &run->s.regs.regs;

  if (!(run->kvm_valid_regs & KVM_SYNC_X86_REGS)) {
    int ret = ioctl(vcpufd, KVM_GET_REGS, kregs);
    if (ret == -1) {
      perror("KVM: KVM_GET_REGS");
      leavedos_main(99);
    }
  }
  if (!(run->kvm_valid_regs & KVM_SYNC_X86_SREGS)) {
    int ret = ioctl(vcpufd, KVM_GET_SREGS, &sregs);
    if (ret == -1) {
      perror("KVM: KVM_GET_SREGS");
      leavedos_main(99);
    }
  }
  /* don't interrupt GDT code */
  if (!(kregs->rflags & X86_EFLAGS_VM) && !(sregs.cs.selector & 4)) {
    g_printf("KVM: interrupt in GDT code, resuming\n");
    return 0;
  }

  regs->eax = kregs->rax;
  regs->ebx = kregs->rbx;
  regs->ecx = kregs->rcx;
  regs->edx = kregs->rdx;
  regs->esi = kregs->rsi;
  regs->edi = kregs->rdi;
  regs->ebp = kregs->rbp;
  regs->esp = kregs->rsp;
  regs->eip = kregs->rip;
  regs->eflags = kregs->rflags;

  regs->cs = sregs.cs.selector;
  regs->ss = sregs.ss.selector;
  if (kregs->rflags & X86_EFLAGS_VM) {
    regs->ds = sregs.ds.selector;
    regs->es = sregs.es.selector;
    regs->fs = sregs.fs.selector;
    regs->gs = sregs.gs.selector;
  } else {
    regs->__null_ds = sregs.ds.selector;
    regs->__null_es = sregs.es.selector;
    regs->__null_fs = sregs.fs.selector;
    regs->__null_gs = sregs.gs.selector;
  }
  return 1;
}

/* Inner loop for KVM, runs until HLT or signal */
static unsigned int kvm_run(struct vm86_regs *regs)
{
  unsigned int exit_reason = 0;
  struct kvm_regs *kregs = &run->s.regs.regs;

  kregs->rax = regs->eax;
  kregs->rbx = regs->ebx;
  kregs->rcx = regs->ecx;
  kregs->rdx = regs->edx;
  kregs->rsi = regs->esi;
  kregs->rdi = regs->edi;
  kregs->rbp = regs->ebp;
  kregs->rsp = regs->esp;
  kregs->rip = regs->eip;
  kregs->rflags = regs->eflags;
  run->kvm_dirty_regs |= KVM_SYNC_X86_REGS;

  if (regs->eflags & X86_EFLAGS_VM) {
    set_vm86_seg(&sregs.cs, regs->cs);
    set_vm86_seg(&sregs.ds, regs->ds);
    set_vm86_seg(&sregs.es, regs->es);
    set_vm86_seg(&sregs.fs, regs->fs);
    set_vm86_seg(&sregs.gs, regs->gs);
    set_vm86_seg(&sregs.ss, regs->ss);
  } else {
    set_ldt_seg(&sregs.cs, regs->cs);
    set_ldt_seg(&sregs.ds, regs->__null_ds);
    set_ldt_seg(&sregs.es, regs->__null_es);
    set_ldt_seg(&sregs.fs, regs->__null_fs);
    set_ldt_seg(&sregs.gs, regs->__null_gs);
    set_ldt_seg(&sregs.ss, regs->ss);
  }
  run->s.regs.sregs = sregs;
  run->kvm_dirty_regs |= KVM_SYNC_X86_SREGS;

  while (!exit_reason) {
    int ret = ioctl(vcpufd, KVM_RUN, NULL);
    int errn = errno;

    /* KVM should only exit for four reasons:
       1. KVM_EXIT_HLT: at the hlt in kvmmon.S following an exception.
          In this case the registers are pushed on and popped from the stack.
       2. KVM_EXIT_INTR: (with ret==-1) after a signal. In this case we
          must restore and save registers using ioctls.
       3. KVM_EXIT_IRQ_WINDOW_OPEN: if it is not possible to inject interrupts
          (or in our case properly interrupt using reason 2)
          KVM is re-entered asking it to exit when interrupt injection is
          possible, then it exits with this code. This only happens if a signal
          occurs during execution of the monitor code in kvmmon.S.
       4. ret==-1 and errno == EFAULT: this can happen if code in vgaemu.c
          calls mprotect in parallel and the TLB is out of sync with the
          actual page tables; if this happen we retry and it should not happen
          again since the KVM exit/entry makes everything sync'ed.
    */
    if (mprotected_kvm) { // case 4
      mprotected_kvm = 0;
      if (ret == -1 && errn == EFAULT)
	ret = ioctl(vcpufd, KVM_RUN, NULL);
    }

    if (ret == -1 && errn == EINTR) {
      if (!kvm_post_run(regs))
        continue;
      exit_reason = KVM_EXIT_INTR;
      break;
    } else if (ret != 0) {
      perror("KVM: KVM_RUN");
      leavedos_main(99);
    }

    switch (run->exit_reason) {
    case KVM_EXIT_HLT:
      exit_reason = KVM_EXIT_HLT;
      break;
    case KVM_EXIT_IRQ_WINDOW_OPEN:
      run->request_interrupt_window = !run->ready_for_interrupt_injection;
      if (run->request_interrupt_window || !run->if_flag) break;
      if (!kvm_post_run(regs))
        break;

      exit_reason = KVM_EXIT_IRQ_WINDOW_OPEN;
      break;
    case KVM_EXIT_FAIL_ENTRY:
      error("KVM_EXIT_FAIL_ENTRY: hardware_entry_failure_reason = 0x%llx\n",
	      (unsigned long long)run->fail_entry.hardware_entry_failure_reason);
      leavedos_main(99);
      break;
    case KVM_EXIT_INTERNAL_ERROR:
      error("KVM_EXIT_INTERNAL_ERROR: suberror = 0x%x\n", run->internal.suberror);
      leavedos_main(99);
      break;
    default:
      error("KVM: exit_reason = 0x%x\n", run->exit_reason);
      leavedos_main(99);
      break;
    }
  }
  return exit_reason;
}

static void kvm_vme_tf_popf_fixup(struct vm86_regs *regs)
{
  if (regs->eip == 0 || !(regs->eflags & X86_EFLAGS_TF))
    return;
  /* The problem was noticed on
   * AMD FX(tm)-8350 Eight-Core Processor
   * stepping: 0 microcode: 0x6000852
   *
   * popfw fails to clear TF flag:
   * https://github.com/dosemu2/dosemu2/issues/1350
   * We need to clear it by hands.
   * We check for popf and assume it tried to clear TF.
   * */
  if (READ_BYTE(SEGOFF2LINEAR(regs->cs, regs->eip - 1)) == 0x9d) {
    error("KVM: applying TF fixup\n");
    regs->eflags &= ~X86_EFLAGS_TF;
  }
}

/* Emulate vm86() using KVM */
int kvm_vm86(struct vm86_struct *info)
{
  struct vm86_regs *regs;
  int vm86_ret;
  unsigned int trapno, exit_reason;

  regs = &monitor->regs;
  *regs = info->regs;
  monitor->int_revectored = info->int_revectored;
  monitor->tss.esp0 = offsetof(struct monitor, regs) + sizeof(monitor->regs);

  regs->eflags &= (SAFE_MASK | X86_EFLAGS_VIF | X86_EFLAGS_VIP);
  regs->eflags |= X86_EFLAGS_FIXED | X86_EFLAGS_VM | X86_EFLAGS_IF;

  do {
    exit_reason = kvm_run(regs);

    vm86_ret = VM86_SIGNAL;
    if (exit_reason != KVM_EXIT_HLT) break;

    /* high word(orig_eax) = exception number */
    /* low word(orig_eax) = error code */
    trapno = (regs->orig_eax >> 16) & 0xff;
#if 1
    if (trapno == 1 && (sregs.cr4 & X86_CR4_VME))
      kvm_vme_tf_popf_fixup(regs);
#endif
    if (trapno == 1 || trapno == 3)
      vm86_ret = VM86_TRAP | (trapno << 8);
    else if (trapno == 0xd)
      vm86_ret = kvm_handle_vm86_fault(regs, info->cpu_type);
  } while (vm86_ret == -1);

  info->regs = *regs;
  info->regs.eflags |= X86_EFLAGS_IOPL;
  if (vm86_ret == VM86_SIGNAL && exit_reason == KVM_EXIT_HLT) {
    unsigned trapno = (regs->orig_eax >> 16) & 0xff;
    unsigned err = regs->orig_eax & 0xffff;
    if (trapno == 0x0e &&
	(vga_emu_fault(monitor->cr2, err, NULL) == True || (
	 config.cpu_vm_dpmi == CPUVM_EMU && !config.cpusim &&
	 e_handle_pagefault(monitor->cr2, err, NULL))))
      return vm86_ret;
    vm86_fault(trapno, err, monitor->cr2);
  }
  return vm86_ret;
}

/* Emulate do_dpmi_control() using KVM */
int kvm_dpmi(sigcontext_t *scp)
{
  struct vm86_regs *regs;
  int ret;
  unsigned int exit_reason;

  monitor->tss.esp0 = offsetof(struct monitor, regs) +
    offsetof(struct vm86_regs, es);

  regs = &monitor->regs;
  do {
    regs->eax = _eax;
    regs->ebx = _ebx;
    regs->ecx = _ecx;
    regs->edx = _edx;
    regs->esi = _esi;
    regs->edi = _edi;
    regs->ebp = _ebp;
    regs->esp = _esp;
    regs->eip = _eip;

    regs->cs = _cs;
    regs->__null_ds = _ds;
    regs->__null_es = _es;
    regs->ss = _ss;
    regs->__null_fs = _fs;
    regs->__null_gs = _gs;

    regs->eflags = _eflags;
    regs->eflags &= (SAFE_MASK | X86_EFLAGS_VIF | X86_EFLAGS_VIP);
    regs->eflags |= X86_EFLAGS_FIXED | X86_EFLAGS_IF;

    exit_reason = kvm_run(regs);

    _eax = regs->eax;
    _ebx = regs->ebx;
    _ecx = regs->ecx;
    _edx = regs->edx;
    _esi = regs->esi;
    _edi = regs->edi;
    _ebp = regs->ebp;
    _esp = regs->esp;
    _eip = regs->eip;

    _cs = regs->cs;
    _ds = regs->__null_ds;
    _es = regs->__null_es;
    _ss = regs->ss;
    _fs = regs->__null_fs;
    _gs = regs->__null_gs;

    _eflags = regs->eflags;
    _eflags |= X86_EFLAGS_IOPL;

    ret = DPMI_RET_DOSEMU; /* mirroring sigio/sigalrm */
    if (exit_reason == KVM_EXIT_HLT) {
      /* orig_eax >> 16 = exception number */
      /* orig_eax & 0xffff = error code */
      _cr2 = (uintptr_t)MEM_BASE32(monitor->cr2);
      _trapno = (regs->orig_eax >> 16) & 0xff;
      _err = regs->orig_eax & 0xffff;
      if (_trapno > 0x10) {
	// convert software ints into the GPFs that the DPMI code expects
	_err = (_trapno << 3) + 2;
	_trapno = 0xd;
	_eip -= 2;
      }

      if (_trapno == 0x10) {
        struct kvm_fpu fpu;
        ioctl(vcpufd, KVM_GET_FPU, &fpu);
#ifdef __x86_64__
        memcpy(__fpstate->_st, fpu.fpr, sizeof __fpstate->_st);
        __fpstate->cwd = fpu.fcw;
        __fpstate->swd = fpu.fsw;
        __fpstate->ftw = fpu.ftwx;
        __fpstate->fop = fpu.last_opcode;
        __fpstate->rip = fpu.last_ip;
        __fpstate->rdp = fpu.last_dp;
        memcpy(__fpstate->_xmm, fpu.xmm, sizeof __fpstate->_xmm);
#else
        memcpy(__fpstate->_st, fpu.fpr, sizeof __fpstate->_st);
        __fpstate->cw = fpu.fcw;
        __fpstate->sw = fpu.fsw;
        __fpstate->tag = fpu.ftwx;
        __fpstate->ipoff = fpu.last_ip;
        __fpstate->cssel = _cs;
        __fpstate->dataoff = fpu.last_dp;
        __fpstate->datasel = _ds;
#endif
        dbug_printf("coprocessor exception, calling IRQ13\n");
        print_exception_info(scp);
        pic_request(PIC_IRQ13);
        ret = DPMI_RET_DOSEMU;
      } else if (_trapno == 0x0e &&
	    (vga_emu_fault(monitor->cr2, _err, scp) == True || (
	    config.cpu_vm == CPUVM_EMU && !config.cpusim &&
	    e_handle_pagefault(monitor->cr2, _err, scp))))
	ret = dpmi_check_return();
      else
	ret = dpmi_fault(scp);
    }
  } while (ret == DPMI_RET_CLIENT);
  return ret;
}

void kvm_done(void)
{
  close(vcpufd);
  close(vmfd);
  close(kvmfd);
  free(cpuid);
}

#endif
