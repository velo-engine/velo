// Platform queries for the safe area (the part of the screen not covered by notches, rounded corners or
// system bars). Each function writes left, top, right, bottom into `out` and returns 1, or returns 0 when
// the platform cannot tell yet (e.g. before the view is attached).

#if defined(__ANDROID__)
#include <jni.h>
#include <android/native_activity.h>

static jobject velo__call_obj(JNIEnv* env, jobject obj, const char* name, const char* sig) {
	if (obj == NULL) return NULL;
	jclass cls = (*env)->GetObjectClass(env, obj);
	jmethodID m = (*env)->GetMethodID(env, cls, name, sig);
	(*env)->DeleteLocalRef(env, cls);
	if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NULL; } // API level too old
	jobject r = (*env)->CallObjectMethod(env, obj, m);
	if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NULL; }
	return r;
}

static int velo__call_int(JNIEnv* env, jobject obj, const char* name) {
	jclass cls = (*env)->GetObjectClass(env, obj);
	jmethodID m = (*env)->GetMethodID(env, cls, name, "()I");
	(*env)->DeleteLocalRef(env, cls);
	if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 0; }
	int r = (*env)->CallIntMethod(env, obj, m);
	if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 0; }
	return r;
}

// Pixels. The larger of the visible system bars (WindowInsets.getSystemWindowInset*, API 23) and the display
// cutout (DisplayCutout.getSafeInset*, API 28), per edge.
static int velo_android_safe_insets(const void* native_activity, int* out) {
	const ANativeActivity* act = (const ANativeActivity*)native_activity;
	if (act == NULL || act->vm == NULL) return 0;
	JavaVM* vm = act->vm;
	JNIEnv* env = NULL;
	if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
		// sokol renders on its own thread; it stays attached so later calls are cheap
		if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return 0;
	}
	int ok = 0;
	jobject window = velo__call_obj(env, act->clazz, "getWindow", "()Landroid/view/Window;");
	jobject decor = velo__call_obj(env, window, "getDecorView", "()Landroid/view/View;");
	jobject insets = velo__call_obj(env, decor, "getRootWindowInsets", "()Landroid/view/WindowInsets;");
	if (insets != NULL) {
		out[0] = velo__call_int(env, insets, "getSystemWindowInsetLeft");
		out[1] = velo__call_int(env, insets, "getSystemWindowInsetTop");
		out[2] = velo__call_int(env, insets, "getSystemWindowInsetRight");
		out[3] = velo__call_int(env, insets, "getSystemWindowInsetBottom");
		jobject cutout = velo__call_obj(env, insets, "getDisplayCutout", "()Landroid/view/DisplayCutout;");
		if (cutout != NULL) {
			const char* names[4] = {"getSafeInsetLeft", "getSafeInsetTop", "getSafeInsetRight", "getSafeInsetBottom"};
			for (int i = 0; i < 4; i++) {
				int v = velo__call_int(env, cutout, names[i]);
				if (v > out[i]) out[i] = v;
			}
			(*env)->DeleteLocalRef(env, cutout);
		}
		(*env)->DeleteLocalRef(env, insets);
		ok = 1;
	}
	if (decor != NULL) (*env)->DeleteLocalRef(env, decor);
	if (window != NULL) (*env)->DeleteLocalRef(env, window);
	return ok;
}
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct { double top, left, bottom, right; } velo__edge_insets; // UIEdgeInsets (CGFloat = double)

// Points. UIView.safeAreaInsets of the key window (iOS 11+).
static int velo_ios_safe_insets(const void* ui_window, double* out) {
#if __has_feature(objc_arc)
	id win = (__bridge id)ui_window; // V compiles iOS builds as Objective-C with ARC
#else
	id win = (id)ui_window;
#endif
	if (win == NULL) return 0;
	SEL sel = sel_registerName("safeAreaInsets");
	if (!class_respondsToSelector(object_getClass(win), sel)) return 0;
#if defined(__x86_64__)
	velo__edge_insets e = ((velo__edge_insets (*)(id, SEL))objc_msgSend_stret)(win, sel);
#else
	velo__edge_insets e = ((velo__edge_insets (*)(id, SEL))objc_msgSend)(win, sel);
#endif
	out[0] = e.left;
	out[1] = e.top;
	out[2] = e.right;
	out[3] = e.bottom;
	return 1;
}
#endif
#endif
