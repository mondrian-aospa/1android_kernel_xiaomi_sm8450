// SPDX-License-Identifier: GPL-2.0
/*
 * Goodix Berlin <-> xiaomi_touch glue
 *
 * Exposes the three wake gestures this device needs over the xiaomi_touch
 * interface, so that they are reachable from
 *
 *   /sys/class/touch/touch_dev/fod_longpress_gesture_enabled
 *   /sys/class/touch/touch_dev/gesture_double_tap_enabled
 *   /sys/class/touch/touch_dev/gesture_single_tap_enabled
 *
 * which is what the sensors.xiaomi sub-HAL writes to arm
 * co.aospa.sensor.{udfps,double_tap,single_tap}. Without this the sysfs
 * stores in xiaomi_touch.c return -ENOMEM because setModeValue/getModeValue
 * were never registered.
 *
 * Modelled on drivers/input/touchscreen/goodix_9916, adapted to the Berlin
 * driver where cd->gesture_type is a software filter and the IC is put into
 * gesture scan mode with a single hw_ops->gesture() call.
 */

#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/string.h>

#include "goodix_ts_core.h"
#include "../xiaomi/xiaomi_touch.h"

static struct goodix_ts_core *gxt_core;
static struct xiaomi_touch_interface gxt_interface;

static u8 gxt_gesture_bit(int mode)
{
	switch (mode) {
	case Touch_Doubletap_Mode:
		return GESTURE_DOUBLE_TAP;
	case Touch_Singletap_Gesture:
		return GESTURE_SINGLE_TAP;
	case Touch_Fod_Longpress_Gesture:
		return GESTURE_FOD_PRESS;
	default:
		return 0;
	}
}

/*
 * Apply a gesture-arming change that happened while the panel was already
 * blanked. In the normal case gsx_gesture_before_suspend() does this at
 * suspend time, but SystemUI enables and disables the doze sensors around
 * the screen-off transition and after every one-shot trigger, so arming can
 * and does land after the touch controller has already been suspended.
 */
static void gxt_apply_while_suspended(struct goodix_ts_core *cd, bool was_armed)
{
	struct goodix_ts_hw_ops *hw_ops = cd->hw_ops;
	bool armed = cd->gesture_type != 0;

	if (armed == was_armed) {
		/* still armed, only the filter mask changed: nothing to send,
		 * the IC already scans and gsx_gesture_ist() does the filtering */
		return;
	}

	if (armed) {
		/*
		 * brl_suspend() cut the rails because nothing was armed when
		 * the panel blanked. Bring the controller back up before it
		 * can scan for gestures.
		 */
		if (goodix_ts_power_on(cd)) {
			ts_err("failed power on for late gesture arm");
			return;
		}
		if (hw_ops->reset(cd, GOODIX_NORMAL_RESET_DELAY_MS)) {
			ts_err("failed reset for late gesture arm");
			return;
		}
		if (hw_ops->gesture(cd, 0))
			ts_err("failed enter gesture mode");
		else
			ts_info("late enter gesture mode, type[0x%02X]",
				cd->gesture_type);

		hw_ops->irq_enable(cd, true);
		goodix_ts_set_irq_wake(cd, true);
	} else {
		/*
		 * Everything disarmed while blanked. Leave the controller in
		 * exactly the state brl_suspend() would have left it in with
		 * nothing armed -- rails down, irq off, no wake -- because
		 * that is the state the matching resume path expects. Merely
		 * dropping the irq would leave the IC powered and still in
		 * gesture scan mode, and brl_resume() would then no-op on the
		 * already-powered rails and never reset it back to coordinate
		 * mode, breaking touch after unblank.
		 */
		goodix_ts_set_irq_wake(cd, false);
		hw_ops->irq_enable(cd, false);
		goodix_ts_power_off(cd);
		ts_info("late leave gesture mode");
	}
}

static int gxt_set_mode_value(int mode, int value)
{
	struct goodix_ts_core *cd = gxt_core;
	u8 bit = gxt_gesture_bit(mode);
	bool was_armed;

	if (!bit) {
		/* Mode we deliberately do not implement (game mode, edge
		 * filter, ...). Accept it so userspace does not treat the
		 * whole device as broken. */
		return 0;
	}

	if (!cd || cd->init_stage != CORE_INIT_STAGE2) {
		ts_err("initialization not completed, ignoring mode %d", mode);
		return 0;
	}

	if (value < 0 || value > 1)
		return -EINVAL;

	mutex_lock(&cd->gesture_mutex);

	was_armed = cd->gesture_type != 0;

	if (value)
		cd->gesture_type |= bit;
	else
		cd->gesture_type &= ~bit;

	gxt_interface.touch_mode[mode][SET_CUR_VALUE] = value;
	gxt_interface.touch_mode[mode][GET_CUR_VALUE] = value;

	ts_info("mode:%d value:%d gesture_type:0x%02X", mode, value,
		cd->gesture_type);

	if (atomic_read(&cd->suspended))
		gxt_apply_while_suspended(cd, was_armed);

	mutex_unlock(&cd->gesture_mutex);

	return 0;
}

static int gxt_get_mode_value(int mode, int value_type)
{
	if (mode < 0 || mode >= Touch_Mode_NUM ||
	    value_type < 0 || value_type >= VALUE_TYPE_SIZE) {
		ts_err("don't support mode %d type %d", mode, value_type);
		return -EINVAL;
	}

	return gxt_interface.touch_mode[mode][value_type];
}

static int gxt_get_mode_all(int mode, int *value)
{
	if (mode < 0 || mode >= Touch_Mode_NUM) {
		ts_err("don't support mode %d", mode);
		return -EINVAL;
	}

	value[0] = gxt_interface.touch_mode[mode][GET_CUR_VALUE];
	value[1] = gxt_interface.touch_mode[mode][GET_DEF_VALUE];
	value[2] = gxt_interface.touch_mode[mode][GET_MIN_VALUE];
	value[3] = gxt_interface.touch_mode[mode][GET_MAX_VALUE];

	return 0;
}

static int gxt_reset_mode(int mode)
{
	if (!gxt_gesture_bit(mode))
		return 0;

	return gxt_set_mode_value(mode,
			gxt_interface.touch_mode[mode][GET_DEF_VALUE]);
}

static void gxt_init_mode_defaults(int mode)
{
	gxt_interface.touch_mode[mode][GET_DEF_VALUE] = 0;
	gxt_interface.touch_mode[mode][GET_MIN_VALUE] = 0;
	gxt_interface.touch_mode[mode][GET_MAX_VALUE] = 1;
	gxt_interface.touch_mode[mode][SET_CUR_VALUE] = 0;
	gxt_interface.touch_mode[mode][GET_CUR_VALUE] = 0;
}

int goodix_xiaomi_touch_init(struct goodix_ts_core *cd)
{
	if (!cd)
		return -EINVAL;

	gxt_core = cd;

	memset(&gxt_interface, 0, sizeof(gxt_interface));
	gxt_interface.setModeValue = gxt_set_mode_value;
	gxt_interface.getModeValue = gxt_get_mode_value;
	gxt_interface.getModeAll = gxt_get_mode_all;
	gxt_interface.resetMode = gxt_reset_mode;

	gxt_init_mode_defaults(Touch_Doubletap_Mode);
	gxt_init_mode_defaults(Touch_Singletap_Gesture);
	gxt_init_mode_defaults(Touch_Fod_Longpress_Gesture);

	xiaomitouch_register_modedata(0, &gxt_interface);
	ts_info("xiaomi_touch mode data registered");

	return 0;
}

/*
 * Clear the FOD press latch. update_fod_press_status() only sysfs_notify()s
 * on a value change, so a FOD-DOWN whose matching FOD-UP was lost -- the IC
 * is reset on both the suspend and resume transitions, which can swallow it --
 * would leave fod_press_status stuck at 1 and silently kill every subsequent
 * screen-off unlock. goodix_9916 clears it on the same transitions.
 */
void goodix_xiaomi_touch_clear_fod(void)
{
	if (gxt_core)
		update_fod_press_status(0);
}

void goodix_xiaomi_touch_exit(void)
{
	gxt_core = NULL;
}
