#import <Sparkle/Sparkle.h>
#import "SUAppcast+Private.h"
#import "SPUAppcastItemStateResolver.h"

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        SPUAppcastItemStateResolver *resolver = [[SPUAppcastItemStateResolver alloc]
            initWithHostVersion:@"7.0.0" applicationVersionComparator:SUStandardVersionComparator.defaultComparator
            standardVersionComparator:SUStandardVersionComparator.defaultComparator];
        NSError *error = nil;
        SUAppcast *feed = [[SUAppcast alloc] initWithXMLData:data relativeToURL:nil stateResolver:resolver
            signingValidationStatus:SPUAppcastSigningValidationStatusSucceeded error:&error];
        if (!feed || feed.items.count != 1) return 1;
        NSDictionary *properties = feed.items.firstObject.propertiesDictionary;
        if (![properties[@"tuff:recovery"] isEqual:@"true"] ||
            ![properties[@"tuff:appSettingsVersion"] isEqual:@"7"]) return 2;
        puts("Sparkle XML parser retained TUFF recovery element text");
    }
    return 0;
}
