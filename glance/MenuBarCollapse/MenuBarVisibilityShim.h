//
//  MenuBarVisibilityShim.h
//  glance
//
//  Adapted from Hidden Bar's HBNativeVisibilityShim (MIT, © 2026 Dwarves Foundation),
//  https://github.com/dwarvesf/hidden — see THIRD_PARTY_NOTICES.md.
//
//  The only boundary to macOS 27's private MenuBarClientCore framework. Objective-C so
//  exceptions a changed private API raises are caught instead of crashing the app.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the framework, both classes and every selector used below resolve.
BOOL GLMenuBarVisibilityIsAvailable(void);

/// Keeps only the given system items and apps visible; macOS hides every other status
/// item and reflows the bar. Completion runs on the main queue with the assertion to
/// hold (hiding lasts until it is invalidated or this process exits) or an error.
void GLMenuBarVisibilityActivate(NSArray<NSNumber *> *allowedSystemItems,
                                 NSArray<NSString *> *allowedBundleIdentifiers,
                                 void (^completion)(id _Nullable assertion, NSError * _Nullable error));

void GLMenuBarVisibilityInvalidate(id assertion);

NS_ASSUME_NONNULL_END
