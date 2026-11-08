//
//  MenuBarVisibilityShim.m
//  glance
//
//  Adapted from Hidden Bar's HBNativeVisibilityShim (MIT, © 2026 Dwarves Foundation),
//  https://github.com/dwarvesf/hidden — see THIRD_PARTY_NOTICES.md.
//
//  MenuBarClientCore is the private framework behind macOS 27's assessment (exam
//  lockdown) mode, which can restrict the menu bar to an allow-list. Resolved at runtime
//  so a macOS release that changes or removes it turns into "unavailable", not a crash.
//

#import "MenuBarVisibilityShim.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const GLFrameworkPath = @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const GLConfigurationClassName = @"MBAssessmentModeConfiguration";
static NSString *const GLAssertionClassName = @"MBAssessmentModeAssertion";

static SEL GLConfigurationInit(void) { return @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:); }
static SEL GLActivate(void) { return @selector(activateWithConfiguration:completionHandler:); }
static SEL GLInvalidate(void) { return @selector(invalidate); }

static NSError *GLError(NSString *reason) {
    return [NSError errorWithDomain:@"GLMenuBarVisibility" code:1
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

BOOL GLMenuBarVisibilityIsAvailable(void) {
    if (!dlopen(GLFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
        return NO;
    }
    Class configuration = NSClassFromString(GLConfigurationClassName);
    Class assertion = NSClassFromString(GLAssertionClassName);
    return configuration && assertion
        && [configuration instancesRespondToSelector:GLConfigurationInit()]
        && [assertion instancesRespondToSelector:GLActivate()]
        && [assertion instancesRespondToSelector:GLInvalidate()];
}

void GLMenuBarVisibilityActivate(NSArray<NSNumber *> *allowedSystemItems,
                                 NSArray<NSString *> *allowedBundleIdentifiers,
                                 void (^completion)(id _Nullable assertion, NSError * _Nullable error)) {
    void (^finish)(id, NSError *) = ^(id assertion, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(assertion, error); });
    };
    if (!GLMenuBarVisibilityIsAvailable()) {
        finish(nil, GLError(@"MenuBarClientCore is unavailable on this macOS"));
        return;
    }
    @try {
        // Both lists must be NSArrays: the framework indexes into them.
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(GLConfigurationClassName) alloc], GLConfigurationInit(),
            [allowedSystemItems copy], [allowedBundleIdentifiers copy]);
        id assertion = [[NSClassFromString(GLAssertionClassName) alloc] init];
        if (!configuration || !assertion) {
            finish(nil, GLError(@"Could not create the visibility configuration"));
            return;
        }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, GLActivate(), configuration, ^(NSError *error) {
                finish(error ? nil : assertion, error);
            });
    } @catch (NSException *exception) {
        finish(nil, GLError([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]));
    }
}

void GLMenuBarVisibilityInvalidate(id assertion) {
    @try {
        if ([assertion respondsToSelector:GLInvalidate()]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, GLInvalidate());
        }
    } @catch (NSException *exception) {
        NSLog(@"MenuBarVisibility: invalidate raised %@: %@", exception.name, exception.reason);
    }
}
