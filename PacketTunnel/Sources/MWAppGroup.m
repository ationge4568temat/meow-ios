#import "MWAppGroup.h"
#import <Security/Security.h>

NSString * MWAppGroupIdentifier(void) {
    static NSString *groupIdentifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task) {
            CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
                NSArray *groups = (__bridge NSArray *)value;
                if (groups.count > 0) {
                    groupIdentifier = groups.firstObject;
                }
            }
            if (value) CFRelease(value);
            CFRelease(task);
        }
        if (!groupIdentifier) {
            groupIdentifier = @"group.ssadtyer.top";
        }
    });
    return groupIdentifier;
}
@implementation MWAppGroup

+ (NSString *)identifier {
    return MWAppGroupIdentifier();
}

+ (NSURL *)containerURL {
    NSURL *url = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:MWAppGroupIdentifier()];
    NSAssert(url, @"App Group container unavailable — entitlement missing '%@'", MWAppGroupIdentifier());
    return url;
}

+ (NSURL *)configURL {
    return [[self containerURL] URLByAppendingPathComponent:@"config.yaml"];
}

+ (NSURL *)effectiveConfigURL {
    return [[self containerURL] URLByAppendingPathComponent:@"effective-config.yaml"];
}

+ (NSURL *)stateURL {
    return [[self containerURL] URLByAppendingPathComponent:@"state.json"];
}

+ (NSURL *)trafficURL {
    return [[self containerURL] URLByAppendingPathComponent:@"traffic.json"];
}

+ (NSUserDefaults *)defaults {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:MWAppGroupIdentifier()];
    NSAssert(d, @"Shared UserDefaults unavailable for suite '%@'", MWAppGroupIdentifier());
    return d;
}

@end
