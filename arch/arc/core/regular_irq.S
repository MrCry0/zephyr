/*
 * Copyright (c) 2014 Wind River Systems, Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * @file
 * @brief Handling of transitions to-and-from regular IRQs (RIRQ)
 *
 * This module implements the code for handling entry to and exit from regular
 * IRQs.
 *
 * See isr_wrapper.S for details.
 */

#include <kernel_structs.h>
#include <offsets_short.h>
#include <toolchain.h>
#include <arch/cpu.h>
#include <swap_macros.h>

GTEXT(_rirq_enter)
GTEXT(_rirq_exit)
GTEXT(_rirq_common_interrupt_swap)
GDATA(exc_nest_count)

#if 0 /* TODO: when FIRQ is not present, all would be regular */
#define NUM_REGULAR_IRQ_PRIO_LEVELS CONFIG_NUM_IRQ_PRIO_LEVELS
#else
#define NUM_REGULAR_IRQ_PRIO_LEVELS (CONFIG_NUM_IRQ_PRIO_LEVELS-1)
#endif
/* note: the above define assumes that prio 0 IRQ is for FIRQ, and
 * that all others are regular interrupts.
 * TODO: Revist this if FIRQ becomes configurable.
 */


/**
 *
 * @brief Work to be done before handing control to an IRQ ISR
 *
 * The processor pushes automatically all registers that need to be saved.
 * However, since the processor always runs at kernel privilege there is no
 * automatic switch to the IRQ stack: this must be done in software.
 *
 * Assumption by _isr_demux: r3 is untouched by _rirq_enter.
 *
 * @return N/A
 */

SECTION_FUNC(TEXT, _rirq_enter)


#ifdef CONFIG_ARC_STACK_CHECKING
#ifdef CONFIG_ARC_HAS_SECURE
	lr r2, [_ARC_V2_SEC_STAT]
	bclr r2, r2, _ARC_V2_SEC_STAT_SSC_BIT
	/* sflag r2 */
	/* sflag instruction is not supported in current ARC GNU */
	.long 0x00bf302f
#else
	/* disable stack checking */
	lr r2, [_ARC_V2_STATUS32]
	bclr r2, r2, _ARC_V2_STATUS32_SC_BIT
	kflag r2
#endif
#endif
	clri
	ld r1, [exc_nest_count]
	add r0, r1, 1
	st r0, [exc_nest_count]
	cmp r1, 0

	bgt.d  rirq_nest
	mov r0, sp

	mov r1, _kernel
	ld sp, [r1, _kernel_offset_to_irq_stack]
rirq_nest:
	push_s r0

	seti
	j _isr_demux


/**
 *
 * @brief Work to be done exiting an IRQ
 *
 * @return N/A
 */

SECTION_FUNC(TEXT, _rirq_exit)
	clri

	pop sp

	mov	r1, exc_nest_count
	ld	r0, [r1]
	sub	r0, r0, 1
	st	r0, [r1]
	/*
	 * using exc_nest_count to decide whether is nest int is not reliable.
	 * a better option is to use IRQ_ACT
	 * A case is:  a high priority int preempts a low priority int before
	 * rirq_enter/firq_enter, then in _rirq_exit/_firq_exit, it will see
	 * exc_nest_cout is 0, this will lead to possible thread switch, but
	 * a low priority int is still pending.
	 *
	 * If multi bits in IRQ_ACT are set, i.e. last bit != fist bit, it's
	 * in nest interrupt
	 */
	lr 	r0, [_ARC_V2_AUX_IRQ_ACT]
	and 	r0, r0, 0xffff
	ffs	r1, r0
	fls	r2, r0
	cmp	r1, r2
	jne	_rirq_return_from_rirq

#ifdef CONFIG_STACK_SENTINEL
	bl z_check_stack_sentinel
#endif

#ifdef CONFIG_PREEMPT_ENABLED

	mov r1, _kernel
	ld_s r2, [r1, _kernel_offset_to_current]

	/*
	 * Lock interrupts to ensure kernel queues do not change from this
	 * point on until return from interrupt.
	 */

	/*
	 * Both (a)reschedule and (b)non-reschedule cases need to load the
	 * current thread's stack, but don't have to use it until the decision
	 * is taken: load the delay slots with the 'load stack pointer'
	 * instruction.
	 *
	 * a) needs to load it to save outgoing context.
	 * b) needs to load it to restore the interrupted context.
	 */

	/* check if the current thread needs to be rescheduled */
	ld_s r0, [r1, _kernel_offset_to_ready_q_cache]
	cmp_s r0, r2
	beq _rirq_no_reschedule

	/* cached thread to run is in r0, fall through */

.balign 4
_rirq_reschedule:

	/* _save_callee_saved_regs expects outgoing thread in r2 */
	_save_callee_saved_regs

	st _CAUSE_RIRQ, [r2, _thread_offset_to_relinquish_cause]

	/* incoming thread is in r0: it becomes the new 'current' */
	mov r2, r0
	st_s r2, [r1, _kernel_offset_to_current]

.balign 4
_rirq_common_interrupt_swap:
	/* r2 contains pointer to new thread */

#ifdef CONFIG_ARC_STACK_CHECKING
	_load_stack_check_regs
#endif
	/*
	 * _load_callee_saved_regs expects incoming thread in r2.
	 * _load_callee_saved_regs restores the stack pointer.
	 */
	_load_callee_saved_regs

#if defined(CONFIG_MPU_STACK_GUARD) || defined(CONFIG_USERSPACE)
	push_s r2
	mov r0, r2
	bl configure_mpu_thread
	pop_s r2
#endif

	ld r3, [r2, _thread_offset_to_relinquish_cause]

	breq r3, _CAUSE_RIRQ, _rirq_return_from_rirq
	nop
	breq r3, _CAUSE_FIRQ, _rirq_return_from_firq
	nop

	/* fall through */

.balign 4
_rirq_return_from_coop:

	/*
	 * status32, sec_stat (when CONFIG_ARC_HAS_SECURE is enabled) and pc
	 * (blink) are already on the stack in the right order
	 */
	ld_s r0, [sp, ___isf_t_status32_OFFSET - ___isf_t_pc_OFFSET]

	/* update status32.ie (explanation in firq_exit:_firq_return_from_coop) */

	ld r3, [r2, _thread_offset_to_intlock_key]
	st  0, [r2, _thread_offset_to_intlock_key]
	cmp r3, 0
	or.ne r0, r0, _ARC_V2_STATUS32_IE

	st_s r0, [sp, ___isf_t_status32_OFFSET - ___isf_t_pc_OFFSET]

	/* carve fake stack */
	sub sp, sp, ___isf_t_pc_OFFSET

	/* update return value on stack */
	ld r0, [r2, _thread_offset_to_return_value]
	st_s r0, [sp, ___isf_t_r0_OFFSET]

	/* reset zero-overhead loops */
	st 0, [sp, ___isf_t_lp_end_OFFSET]

	/*
	 * r13 is part of both the callee and caller-saved register sets because
	 * the processor is only able to save registers in pair in the regular
	 * IRQ prologue. r13 thus has to be set to its correct value in the IRQ
	 * stack frame.
	 */
	st_s r13, [sp, ___isf_t_r13_OFFSET]

	/* stack now has the IRQ stack frame layout, pointing to r0 */

	/* fall through to rtie instruction */

	/* rtie will pop the rest from the stack */

	/* fall through to rtie instruction */

#endif /* CONFIG_PREEMPT_ENABLED */

.balign 4
_rirq_return_from_firq:
_rirq_return_from_rirq:
_rirq_no_reschedule:

	rtie
