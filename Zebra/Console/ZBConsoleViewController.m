//
//  ZBConsoleViewController.m
//  Zebra
//
//  Created by Wilson Styres on 2/6/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBConsoleViewController.h"
#import "ZBStage.h"

#import <Database/ZBDatabaseManager.h>
#import <Downloads/ZBDownloadManager.h>
#import <Tabs/ZBTabBarController.h>
#import <Tabs/Packages/Helpers/ZBPackage.h>
#import <Queue/ZBQueue.h>
#import <ZBAppDelegate.h>
#import <ZBDevice.h>
#import <ZBLog.h>

#include <sysexits.h>

@import Crashlytics;
@import LNPopupController;

@interface ZBConsoleViewController () {
    NSMutableArray *applicationBundlePaths;
    NSMutableArray *uicaches;
    NSMutableArray *installedPackageIdentifiers;
    NSMutableDictionary <NSString *, NSNumber *> *downloadMap;
    NSString *localInstallPath;
    ZBDownloadManager *downloadManager;
    ZBQueue *queue;
    ZBStage currentStage;
    BOOL downloadFailed;
    BOOL respringRequired;
    BOOL suppressCancel;
    BOOL updateIconCache;
    BOOL zebraRestartRequired;
}
@property (strong, nonatomic) IBOutlet UIButton *completeButton;
@property (strong, nonatomic) IBOutlet UIBarButtonItem *cancelOrCloseButton;
@property (strong, nonatomic) IBOutlet UILabel *progressText;
@property (strong, nonatomic) IBOutlet UIProgressView *progressView;
@property (strong, nonatomic) IBOutlet UITextView *consoleView;
@end

@implementation ZBConsoleViewController

@synthesize completeButton;
@synthesize cancelOrCloseButton;
@synthesize progressText;
@synthesize progressView;
@synthesize consoleView;

#pragma mark - Initializers

- (id)init {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle: nil];
    self = [storyboard instantiateViewControllerWithIdentifier:@"consoleViewController"];
    
    if (self) {
        applicationBundlePaths = [NSMutableArray new];
        queue = [ZBQueue sharedQueue];
        if ([queue needsToDownloadPackages]) {
            downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self];
            downloadMap = [NSMutableDictionary new];
        }
        installedPackageIdentifiers = [NSMutableArray new];
        respringRequired = NO;
        updateIconCache = NO;
    }
    
    return self;
}

- (id)initWithLocalFile:(NSString *)filePath {
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle: nil];
    self = [storyboard instantiateViewControllerWithIdentifier:@"consoleViewController"];
    
    if (self) {
        applicationBundlePaths = [NSMutableArray new];
        installedPackageIdentifiers = [NSMutableArray new];
        localInstallPath = filePath;
        respringRequired = NO;
        updateIconCache = NO;
        
        // Resume database operations
        [[ZBDatabaseManager sharedInstance] setHaltDatabaseOperations:false];
    }
    
    return self;
}

#pragma mark - View Controller Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"Console", @"");
    
    NSError *error;
    if ([ZBDevice isSlingshotBrokenWithError:&error]) {
        [ZBAppDelegate sendAlertFrom:self message:error.localizedDescription];
    }
    
    [self setupView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (@available(iOS 11.0, *)) {
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
    
    if (currentStage == -1) { //Only run the process once per console cycle
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
        });
        
        if (downloadManager) {
            [self updateStage:ZBStageDownload];
            [downloadManager downloadPackages:[queue packagesToDownload]];
        }
        else {
            [self performSelectorInBackground:@selector(performTasks) withObject:NULL];
        }
    }
}

- (void)setupView {
    currentStage = -1;
    downloadFailed = NO;
    updateIconCache = NO;
    respringRequired = NO;
    suppressCancel = NO;
    zebraRestartRequired = NO;
    installedPackageIdentifiers = [NSMutableArray new];
    applicationBundlePaths = [NSMutableArray new];
    downloadMap = [NSMutableDictionary new];
    
    [self updateProgress:0.0];
    progressText.layer.cornerRadius = 3.0;
    progressText.layer.masksToBounds = YES;
    [self updateProgressText:nil];
    [self setProgressViewHidden:true];
    [self setProgressTextHidden:true];
    [self updateCancelOrCloseButton];
    
    [self.navigationController.navigationBar setBarStyle:UIBarStyleBlack];
    [self.navigationItem setHidesBackButton:true];
    [self.navigationController.navigationBar setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}];
    
    [[[[ZBAppDelegate tabBarController] popupContentView] popupInteractionGestureRecognizer] setDelegate:self];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return false;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark - Performing Tasks

- (void)performTasks {
    if (localInstallPath != NULL) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/libexec/zebra/supersling"];
        [task setArguments:@[@"dpkg", @"-i", localInstallPath]];
        
        NSPipe *outputPipe = [[NSPipe alloc] init];
        NSFileHandle *output = [outputPipe fileHandleForReading];
        [output waitForDataInBackgroundAndNotify];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedData:) name:NSFileHandleDataAvailableNotification object:output];
        
        NSPipe *errorPipe = [[NSPipe alloc] init];
        NSFileHandle *error = [errorPipe fileHandleForReading];
        [error waitForDataInBackgroundAndNotify];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedErrorData:) name:NSFileHandleDataAvailableNotification object:error];
        
        [task setStandardOutput:outputPipe];
        [task setStandardError:errorPipe];
        
        [task launch];
        [task waitUntilExit];
        
        [self refreshLocalPackages];
        [self removeAllDebs];
        [self finishTasks];
    }
    else {
        [self performTasksForDownloadedFiles:NULL];
    }
}

- (void)performTasksForDownloadedFiles:(NSArray *_Nullable)downloadedFiles {
    if (downloadFailed) {
        [self writeToConsole:[NSString stringWithFormat:@"\n%@\n\n%@", NSLocalizedString(@"One or more packages failed to download.", @""), NSLocalizedString(@"Click \"Return to Queue\" to return to the Queue and retry the download.", @"")] atLevel:ZBLogLevelDescript];
        [self finishTasks];
    }
    else {
        NSArray *actions = [queue tasksToPerform:downloadedFiles];
        BOOL zebraModification = queue.zebraPath || queue.removingZebra;
        if ([actions count] == 0 && !zebraModification) {
            [self writeToConsole:NSLocalizedString(@"There are no actions to perform", @"") atLevel:ZBLogLevelDescript];
        }
        else {
            [self setProgressTextHidden:false];
            [self updateProgressText:NSLocalizedString(@"Performing Actions...", @"")];
            for (NSArray *command in actions) {
                if ([command count] == 1) {
                    [self updateStage:(ZBStage)[command[0] intValue]];
                }
                else {
                    for (int i = COMMAND_START; i < [command count]; ++i) {
                        NSString *packageID = command[i];
                        if (![self isValidPackageID:packageID]) continue;
                        
                        if ([ZBPackage containsApplicationBundle:packageID]) {
                            updateIconCache = YES;
                            NSString *path = [ZBPackage pathForApplication:packageID];
                            if (path != NULL) {
                                [applicationBundlePaths addObject:path];
                            }
                        }

                        if (!respringRequired) {
                            respringRequired = [ZBPackage respringRequiredFor:packageID];
                        }
                        
                        if (currentStage != ZBStageRemove) {
                            [installedPackageIdentifiers addObject:packageID];
                        }
                    }
                    
                    zebraRestartRequired = queue.zebraPath || queue.removingZebra;
                    
                    if (![ZBDevice needsSimulation]) {
                        ZBLog(@"[Zebra] Executing commands...");
                        NSTask *task = [[NSTask alloc] init];
                        [task setLaunchPath:@"/usr/libexec/zebra/supersling"];
                        [task setArguments:command];
                        
                        NSPipe *outputPipe = [[NSPipe alloc] init];
                        NSFileHandle *output = [outputPipe fileHandleForReading];
                        [output waitForDataInBackgroundAndNotify];
                        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedData:) name:NSFileHandleDataAvailableNotification object:output];
                        
                        NSPipe *errorPipe = [[NSPipe alloc] init];
                        NSFileHandle *error = [errorPipe fileHandleForReading];
                        [error waitForDataInBackgroundAndNotify];
                        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedErrorData:) name:NSFileHandleDataAvailableNotification object:error];
                        
                        [task setStandardOutput:outputPipe];
                        [task setStandardError:errorPipe];
                        
                        @try {
                            [task launch];
                            [task waitUntilExit];
                            
                            int terminationStatus = [task terminationStatus];
                            switch (terminationStatus) {
                                case EX_NOPERM:
                                    [self writeToConsole:NSLocalizedString(@"Zebra was unable to complete this command because it does not have the proper permissions. Please verify the permissions located at /usr/libexec/zebra/supersling and report this issue on GitHub.", @"") atLevel:ZBLogLevelError];
                                    break;
                                case EDEADLK:
                                    [self writeToConsole:NSLocalizedString(@"ERROR: Unable to lock status file. Please try again.", @"") atLevel:ZBLogLevelError];
                                    break;
                                case 85: //ERESTART apparently
                                    [self writeToConsole:NSLocalizedString(@"ERROR: Process must be restarted. Please try again.", @"") atLevel:ZBLogLevelError];
                                    break;
                                default:
                                    break;
                            }
                        } @catch (NSException *e) {
                            NSString *message = [NSString stringWithFormat:@"Could not complete %@ process. Reason: %@.", [ZBDevice packageManagementBinary],  e.reason];
                            
                            CLS_LOG(@"%@", message);
                            NSLog(@"[Zebra] %@", message);
                            [self writeToConsole:message atLevel:ZBLogLevelError];
                        }
                    }
                    else {
                        [self writeToConsole:@"This device is simulated, here are the packages that would be modified in this stage:" atLevel:ZBLogLevelWarning];
                        for (int i = COMMAND_START; i < [command count]; ++i) {
                            NSString *packageID = command[i];
                            if (![self isValidPackageID:packageID]) continue;
                            [self writeToConsole:[packageID lastPathComponent] atLevel:ZBLogLevelDescript];
                        }
                    }
                }
            }
            
            uicaches = [NSMutableArray new];
            for (int i = 0; i < [installedPackageIdentifiers count]; i++) {
                NSString *packageIdentifier = installedPackageIdentifiers[i];
                if ([ZBPackage containsApplicationBundle:packageIdentifier]) {
                    updateIconCache = YES;
                    NSString *actualPackageIdentifier = packageIdentifier;
                    if ([packageIdentifier hasSuffix:@".deb"]) {
                        // Transform deb-path-like packageID into actual package ID for checking to prevent duplicates
                        actualPackageIdentifier = [[packageIdentifier lastPathComponent] stringByDeletingPathExtension];
                        // ex., com.xxx.yyy_1.0.0_iphoneos_arm.deb
                        NSRange underscoreRange = [actualPackageIdentifier rangeOfString:@"_" options:NSLiteralSearch];
                        if (underscoreRange.location != NSNotFound) {
                            actualPackageIdentifier = [actualPackageIdentifier substringToIndex:underscoreRange.location];
                        }
                        if ([uicaches containsObject:actualPackageIdentifier])
                            continue;
                    }
                    if (![uicaches containsObject:actualPackageIdentifier])
                        [uicaches addObject:actualPackageIdentifier];
                }
                
                if (!respringRequired) {
                    respringRequired |= [ZBPackage respringRequiredFor:packageIdentifier];
                }
            }
            
            if (zebraModification) { //Zebra should be the last thing installed so here is our chance to install it.
                if (queue.removingZebra) {
                    [self postStatusUpdate:NSLocalizedString(@"Removing Zebra...", @"") atLevel:ZBLogLevelInfo];
                    [self postStatusUpdate:@"Goodbye forever :(" atLevel:ZBLogLevelDescript];
                }
                else {
                    [self postStatusUpdate:NSLocalizedString(@"Installing Zebra...", @"") atLevel:ZBLogLevelInfo];
                }
                
                NSString *path = queue.zebraPath;
                
                NSArray *baseCommand;
                if ([[ZBDevice packageManagementBinary] isEqualToString:@"/usr/bin/dpkg"]) {
                    baseCommand = @[@"dpkg", queue.removingZebra ? @"-r" : @"-i", queue.zebraPath ? path : @"xyz.willy.zebra"];
                }
                else {
                    baseCommand = @[@"apt", @"-yqf", @"--allow-downgrades", @"-oApt::Get::HideAutoRemove=true", @"-oquiet::NoProgress=true", @"-oquiet::NoStatistic=true", queue.removingZebra ? @"remove" : @"install", queue.zebraPath ? path : @"xyz.willy.zebra"];
                }
                
                if (![ZBDevice needsSimulation]) {
                    NSTask *task = [[NSTask alloc] init];
                    [task setLaunchPath:@"/usr/libexec/zebra/supersling"];
                    [task setArguments:baseCommand];
                    
                    NSPipe *outputPipe = [[NSPipe alloc] init];
                    NSFileHandle *output = [outputPipe fileHandleForReading];
                    [output waitForDataInBackgroundAndNotify];
                    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedData:) name:NSFileHandleDataAvailableNotification object:output];
                    
                    NSPipe *errorPipe = [[NSPipe alloc] init];
                    NSFileHandle *error = [errorPipe fileHandleForReading];
                    [error waitForDataInBackgroundAndNotify];
                    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedErrorData:) name:NSFileHandleDataAvailableNotification object:error];
                    
                    [task setStandardOutput:outputPipe];
                    [task setStandardError:errorPipe];
                    
                    @try {
                        [task launch];
                        [task waitUntilExit];
                        
                        int terminationStatus = [task terminationStatus];
                        switch (terminationStatus) {
                            case EX_NOPERM:
                                [self writeToConsole:NSLocalizedString(@"Zebra was unable to complete this command because it does not have the proper permissions. Please verify the permissions located at /usr/libexec/zebra/supersling and report this issue on GitHub.", @"") atLevel:ZBLogLevelError];
                                break;
                            case EDEADLK:
                                [self writeToConsole:NSLocalizedString(@"ERROR: Unable to lock status file. Please try again.", @"") atLevel:ZBLogLevelError];
                                break;
                            case 85: //ERESTART apparently
                                [self writeToConsole:NSLocalizedString(@"ERROR: Process must be restarted. Please try again.", @"") atLevel:ZBLogLevelError];
                                    break;
                            default:
                                break;
                        }
                    } @catch (NSException *e) {
                        NSString *message = [NSString stringWithFormat:@"Could not complete %@ process. Reason: %@.", [ZBDevice packageManagementBinary],  e.reason];
                        
                        CLS_LOG(@"%@", message);
                        NSLog(@"[Zebra] %@", message);
                        [self writeToConsole:message atLevel:ZBLogLevelError];
                        [self writeToConsole:@"Please restart Zebra and see if the issue still persists. If so, please file an issue on GitHub." atLevel:ZBLogLevelInfo];
                    }
                }
                else {
                    [self writeToConsole:@"This device is simulated, here are the packages that would be modified in this stage:" atLevel:ZBLogLevelWarning];
                    queue.removingZebra ? [self writeToConsole:@"xyz.willy.zebra" atLevel:ZBLogLevelDescript] : [self writeToConsole:[path lastPathComponent] atLevel:ZBLogLevelDescript];
                }
            }
            
            if (!zebraRestartRequired && updateIconCache) {
                [self updateIconCaches];
            }
            
            [self refreshLocalPackages];
            [self removeAllDebs];
            [self finishTasks];
        }
    }
}

- (void)finishTasks {
    ZBLog(@"[Zebra] Finishing tasks");
    [downloadMap removeAllObjects];
    [applicationBundlePaths removeAllObjects];
    [installedPackageIdentifiers removeAllObjects];
    
    [self updateStage:ZBStageFinished];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    });
}

#pragma mark - Button Actions

- (void)cancel {
    if (suppressCancel)
        return;
    
    [downloadManager stopAllDownloads];
    [downloadMap removeAllObjects];
    [self updateProgress:1.0];
    [self setProgressViewHidden:true];
    [self updateProgressText:nil];
    [self setProgressTextHidden:true];
    [self removeAllDebs];
    [self updateStage:ZBStageFinished];
}

- (void)close {
    [queue clear];
    [[self navigationController] popToRootViewControllerAnimated:true];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBUpdateNavigationButtons" object:nil];
}

- (IBAction)cancelOrClose:(id)sender {
    if (currentStage == ZBStageFinished) {
        [self close];
    } else {
        [self cancel];
    }
}

- (void)returnToQueue {
    [self.navigationController popViewControllerAnimated:true];
}

- (void)closeZebra {
    if (![ZBDevice needsSimulation]) {
        if (uicaches.count > 1) {
            [self updateIconCaches];
        } else {
            [ZBDevice uicache:@[@"-p", @"/Applications/Zebra.app"] observer:self];
        }
    }
    exit(0);
}

- (void)restartSpringBoard {
    if (![ZBDevice needsSimulation]) {
        [ZBDevice restartSpringBoard ];
    } else {
        [self close];
    }
}

#pragma mark - Helper Methods

- (void)updateIconCaches {
    [self writeToConsole:NSLocalizedString(@"Updating icon cache asynchronously...", @"") atLevel:ZBLogLevelInfo];
    NSMutableArray *arguments = [NSMutableArray new];
    if (uicaches.count + applicationBundlePaths.count > 1) {
        [arguments addObject:@"-a"];
        [self writeToConsole:NSLocalizedString(@"This may take awhile and Zebra may crash. It is okay if it does.", @"") atLevel:ZBLogLevelWarning];
    }
    else {
        [arguments addObject:@"-p"];
        for (NSString *packageID in [uicaches copy]) {
            if ([packageID isEqualToString:[ZBAppDelegate bundleID]])
                continue;
            NSString *bundlePath = [ZBPackage pathForApplication:packageID];
            if (bundlePath != NULL)
                [applicationBundlePaths addObject:bundlePath];
        }
        [arguments addObjectsFromArray:applicationBundlePaths];
    }
    
    if (![ZBDevice needsSimulation]) {
        [ZBDevice uicache:arguments observer:self];
    } else {
        [self writeToConsole:@"uicache is not available on the simulator" atLevel:ZBLogLevelWarning];
    }
}

- (void)updateStage:(ZBStage)stage {
    currentStage = stage;
    suppressCancel = stage != ZBStageDownload && stage != ZBStageFinished;
    
    switch (stage) {
        case ZBStageDownload:
            [self updateTitle:NSLocalizedString(@"Downloading", @"")];
            [self writeToConsole:NSLocalizedString(@"Downloading Packages...", @"") atLevel:ZBLogLevelInfo];
            
            [self setProgressTextHidden:false];
            [self setProgressViewHidden:false];
            break;
        case ZBStageInstall:
            [self updateTitle:NSLocalizedString(@"Installing", @"")];
            [self writeToConsole:NSLocalizedString(@"Installing Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageRemove:
            [self updateTitle:NSLocalizedString(@"Removing", @"")];
            [self writeToConsole:NSLocalizedString(@"Removing Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageReinstall:
            [self updateTitle:NSLocalizedString(@"Reinstalling", @"")];
            [self writeToConsole:NSLocalizedString(@"Reinstalling Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageUpgrade:
            [self updateTitle:NSLocalizedString(@"Upgrading", @"")];
            [self writeToConsole:NSLocalizedString(@"Upgrading Packages...", @"") atLevel:ZBLogLevelInfo];
            break;
        case ZBStageFinished:
            [self updateTitle:NSLocalizedString(@"Complete", @"")];
            [self writeToConsole:NSLocalizedString(@"Finished!", @"") atLevel:ZBLogLevelInfo];
            [self updateCompleteButton];
            break;
        default:
            break;
    }
    
    [self setProgressViewHidden:stage != ZBStageDownload];
    [self updateCancelOrCloseButton];
}

- (BOOL)isValidPackageID:(NSString *)packageID {
    return ![packageID hasPrefix:@"-"] && ![packageID isEqualToString:@"install"] && ![packageID isEqualToString:@"remove"];
}

- (void)refreshLocalPackages {
    ZBDatabaseManager *databaseManager = [ZBDatabaseManager sharedInstance];
    [databaseManager addDatabaseDelegate:self];
    [databaseManager importLocalPackagesAndCheckForUpdates:YES sender:self];
}

- (void)removeAllDebs {
    ZBLog(@"[Zebra] Removing all debs");
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:[ZBAppDelegate debsLocation]];
    NSString *file;

    while (file = [enumerator nextObject]) {
        NSError *error = nil;
        BOOL result = [[NSFileManager defaultManager] removeItemAtPath:[[ZBAppDelegate debsLocation] stringByAppendingPathComponent:file] error:&error];

        if (!result && error) {
            NSLog(@"[Zebra] Error while removing %@: %@", file, error);
        }
    }
}

#pragma mark - UI Updates

- (void)setProgressViewHidden:(BOOL)hidden {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->progressView.hidden = hidden;
    });
}

- (void)setProgressTextHidden:(BOOL)hidden {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->progressText.hidden = hidden;
    });
}

- (void)updateProgress:(CGFloat)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->progressView setProgress:progress animated:true];
    });
}

- (void)updateProgressText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->progressText.text = text;
    });
}

- (void)updateTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setTitle:[NSString stringWithFormat:@" %@ ", title]];
    });
}

- (void)writeToConsole:(NSString *)str atLevel:(ZBLogLevel)level {
    if (str == NULL)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIColor *color;
        UIFont *font;
        switch (level) {
            case ZBLogLevelDescript:
                color = [UIColor whiteColor];
                font = [UIFont fontWithName:@"CourierNewPSMT" size:12.0];
                break;
            case ZBLogLevelInfo:
                color = [UIColor whiteColor];
                font = [UIFont fontWithName:@"CourierNewPS-BoldMT" size:12.0];
                break;
            case ZBLogLevelError:
                color = [UIColor redColor];
                font = [UIFont fontWithName:@"CourierNewPS-BoldMT" size:12.0];
                break;
            case ZBLogLevelWarning:
                color = [UIColor yellowColor];
                font = [UIFont fontWithName:@"CourierNewPSMT" size:12.0];
                break;
            default:
                color = [UIColor whiteColor];
                break;
        }

        NSDictionary *attrs = @{ NSForegroundColorAttributeName: color, NSFontAttributeName: font };
        
        //Adds a newline if there is not already one
        NSString *string = [str copy];
        NSString *lastChar = [string substringFromIndex:[string length] - 1];
        if (![lastChar isEqualToString:@"\n"]) {
            string = [str stringByAppendingString:@"\n"];
        }
        
        if (string == NULL)
            return;
        
        [self->consoleView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:string attributes:attrs]];

        if (self->consoleView.text.length) {
            NSRange bottom = NSMakeRange(self->consoleView.text.length - 1, 1);
            [self->consoleView scrollRangeToVisible:bottom];
        }
    });
}

- (void)clearConsole {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->consoleView.text = nil;
    });
}

- (void)updateCancelOrCloseButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->suppressCancel) {
            self.cancelOrCloseButton.enabled = NO;
        }
        else if (self->currentStage == ZBStageFinished) {
            self.cancelOrCloseButton.enabled = !self->zebraRestartRequired;
            [self.cancelOrCloseButton setTitle:NSLocalizedString(@"Close", @"")];
        }
        else {
            self.cancelOrCloseButton.enabled = YES;
            [self.cancelOrCloseButton setTitle:NSLocalizedString(@"Cancel", @"")];
        }
        
        if (self.cancelOrCloseButton.enabled) {
            [self.cancelOrCloseButton setTintColor:[UIColor whiteColor]];
        }
        else {
            [self.cancelOrCloseButton setTintColor:[UIColor clearColor]];
        }
    });
}

- (void)updateCompleteButton {
    ZBLog(@"[Zebra] Final statuses: downloadFailed(%d), respringRequired(%d), zebraRestartRequired(%d)", downloadFailed, respringRequired, zebraRestartRequired);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->completeButton.hidden = NO;
        [self updateProgressText:nil];
        if (self->downloadFailed) {
            [self->completeButton setTitle:NSLocalizedString(@"Return to Queue", @"") forState:UIControlStateNormal];
            [self->completeButton addTarget:self action:@selector(returnToQueue) forControlEvents:UIControlEventTouchUpInside];
        }
        else if (self->respringRequired) {
            [self->completeButton setTitle:NSLocalizedString(@"Restart SpringBoard", @"") forState:UIControlStateNormal];
            [self->completeButton addTarget:self action:@selector(restartSpringBoard) forControlEvents:UIControlEventTouchUpInside];
        }
        else if (self->zebraRestartRequired) {
            [self->completeButton setTitle:NSLocalizedString(@"Close Zebra", @"") forState:UIControlStateNormal];
            [self->completeButton addTarget:self action:@selector(closeZebra) forControlEvents:UIControlEventTouchUpInside];
        }
        else {
            [self->completeButton setTitle:NSLocalizedString(@"Done", @"") forState:UIControlStateNormal];
            [self->completeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
        }
    });
}

#pragma mark - Command Delegate

- (void)receivedData:(NSNotification *)notif {
    NSFileHandle *fh = [notif object];
    NSData *data = [fh availableData];

    if (data.length) {
        [fh waitForDataInBackgroundAndNotify];
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self writeToConsole:str atLevel:ZBLogLevelDescript];
    }
}

- (void)receivedErrorData:(NSNotification *)notif {
    NSFileHandle *fh = [notif object];
    NSData *data = [fh availableData];

    if (data.length) {
        [fh waitForDataInBackgroundAndNotify];
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        CLS_LOG(@"DPKG/APT Error: %@", str);
        if ([str rangeOfString:@"warning"].location != NSNotFound) {
            str = [str stringByReplacingOccurrencesOfString:@"dpkg: " withString:@""];
            [self writeToConsole:str atLevel:ZBLogLevelWarning];
        } else if ([str rangeOfString:@"error"].location != NSNotFound) {
            str = [str stringByReplacingOccurrencesOfString:@"dpkg: " withString:@""];
            [self writeToConsole:str atLevel:ZBLogLevelError];
        }
    }
}

#pragma mark - Download Delegate

- (void)predator:(nonnull ZBDownloadManager *)downloadManager progressUpdate:(CGFloat)progress forPackage:(ZBPackage *)package {
    downloadMap[package.identifier] = @(progress);
    CGFloat totalProgress = 0;
    for (NSString *packageID in downloadMap) {
        totalProgress += [downloadMap[packageID] doubleValue];
    }
    totalProgress /= downloadMap.count;
    [self updateProgress:totalProgress];
    [self updateProgressText:[NSString stringWithFormat: @"%@: %.1f%% ", NSLocalizedString(@"Downloading", @""), totalProgress * 100]];
}

- (void)predator:(nonnull ZBDownloadManager *)downloadManager finishedAllDownloads:(NSDictionary *)filenames {
    [self updateProgressText:nil];
    
    NSArray *debs = [filenames objectForKey:@"debs"];
    [self performSelectorInBackground:@selector(performTasksForDownloadedFiles:) withObject:debs];
    suppressCancel = YES;
    [self updateCancelOrCloseButton];
}

- (void)predator:(nonnull ZBDownloadManager *)downloadManager startedDownloadForFile:(nonnull NSString *)filename {
    [self writeToConsole:[NSString stringWithFormat:@"%@ %@", NSLocalizedString(@"Downloading", @""), filename] atLevel:ZBLogLevelDescript];
}

- (void)predator:(nonnull ZBDownloadManager *)downloadManager finishedDownloadForFile:(NSString *_Nullable)filename withError:(NSError * _Nullable)error {
    if (error != NULL) {
        downloadFailed = YES;
        [self writeToConsole:error.localizedDescription atLevel:ZBLogLevelError];
    }
    else if (filename) {
        [self writeToConsole:[NSString stringWithFormat:@"%@ %@", NSLocalizedString(@"Done", @""), filename] atLevel:ZBLogLevelDescript];
    }
}

#pragma mark - Database Delegate

- (void)postStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    [self writeToConsole:status atLevel:level];
}

- (void)databaseStartedUpdate {
    [self writeToConsole:NSLocalizedString(@"Importing local packages.", @"") atLevel:ZBLogLevelInfo];
}

- (void)databaseCompletedUpdate:(int)packageUpdates {
    [self writeToConsole:NSLocalizedString(@"Finished importing local packages.", @"") atLevel:ZBLogLevelInfo];
    if (packageUpdates != -1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[ZBAppDelegate tabBarController] setPackageUpdateBadgeValue:packageUpdates];
        });
    }
}

@end
