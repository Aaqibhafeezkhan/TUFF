#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface FixtureDelegate : NSObject <SPUUpdaterDelegate>
@property(nonatomic) BOOL found;
@property(nonatomic) BOOL recovery;
@property(nonatomic) BOOL cancelledInstallation;
@end
@implementation FixtureDelegate
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    self.found = YES;
    self.recovery = [item.propertiesDictionary[@"tuff:recovery"] isEqual:@"true"];
}
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    printf("{\"found\":%s,\"recovery\":%s,\"cancelled_installation\":%s,\"error_code\":%ld}\n",
        self.found ? "true" : "false", self.recovery ? "true" : "false",
        self.cancelledInstallation ? "true" : "false", (long)error.code);
    fflush(stdout);
    exit(error && error.code != SUNoUpdateError ? 1 : 0);
}
@end

@interface CancelInstallDriver : SPUStandardUserDriver
@property(nonatomic) FixtureDelegate *fixture;
@end
@implementation CancelInstallDriver
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    self.fixture.cancelledInstallation = YES;
    reply(SPUUserUpdateChoiceSkip);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        FixtureDelegate *delegate = [FixtureDelegate new];
        BOOL interrupt = argc > 2 && strcmp(argv[2], "--interrupt-install") == 0;
        SPUStandardUserDriver *driver = interrupt
            ? [[CancelInstallDriver alloc] initWithHostBundle:bundle delegate:nil]
            : [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:nil];
        if (interrupt) ((CancelInstallDriver *)driver).fixture = delegate;
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:delegate];
        NSError *error = nil;
        if (![updater startUpdater:&error]) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (interrupt) [updater checkForUpdates]; else [updater checkForUpdateInformation];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(3); });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
