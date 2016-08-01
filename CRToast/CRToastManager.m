//
//  CRToast
//  Copyright (c) 2014-2015 Collin Ruffenach. All rights reserved.
//  Copyright (c) 2016 vhnvn.
//

#import "CRToastManager.h"
#import "CRToast.h"
#import "CRToastView.h"
#import "CRToastViewController.h"
#import "CRToastWindow.h"
#import "CRToastLayoutHelpers.h"

static NSUInteger maxNotifications = 10;

@interface CRToast (CRToastManager)
+ (void)setDefaultOptions:(NSDictionary*)defaultOptions;
+ (instancetype)notificationWithOptions:(NSDictionary*)options appearanceBlock:(void (^)(void))appearance completionBlock:(void (^)(void))completion;
@end

@interface CRToastManager () <UICollisionBehaviorDelegate>
@property (nonatomic) BOOL isLayoutRequested;
@property (atomic) BOOL isInLayout;
@property (atomic) BOOL notificationUpdateProcessed;
@property (nonatomic, readonly) NSUInteger showingNotificationsCount;
@property (nonatomic, strong) UIWindow *notificationWindow;
@property (nonatomic, strong) UIView *statusBarView;
@property (nonatomic, strong) NSMutableArray *showingNotifications;
@property (nonatomic, strong) NSMutableArray *notifications;
@property (nonatomic, copy) void (^gravityAnimationCompletionBlock)(BOOL finished);
@property (atomic) NSMutableArray* operationQueue;
@end

static NSString *const kCRToastManagerCollisionBoundryIdentifier = @"kCRToastManagerCollisionBoundryIdentifier";

typedef void (^CRToastAnimationCompletionBlock)(BOOL animated);
typedef void (^CRToastAnimationStepBlock)(void);

@implementation CRToastManager

+ (void)setMaxNotifications:(NSUInteger)_maxNotifications
{
    maxNotifications = _maxNotifications;
}

+ (void)setDefaultOptions:(NSDictionary*)defaultOptions {
    [CRToast setDefaultOptions:defaultOptions];
}

+ (void)showNotificationWithMessage:(NSString*)message completionBlock:(void (^)(void))completion {
    [self showNotificationWithOptions:@{kCRToastTextKey : message}
                      completionBlock:completion];
}

+ (void)showNotificationWithOptions:(NSDictionary*)options completionBlock:(void (^)(void))completion {
    [self showNotificationWithOptions:options
                       apperanceBlock:nil
                      completionBlock:completion];
}

+ (void)showNotificationWithOptions:(NSDictionary*)options
                     apperanceBlock:(void (^)(void))appearance
                    completionBlock:(void (^)(void))completion
{
    [[CRToastManager manager] addNotification:[CRToast notificationWithOptions:options
                                                               appearanceBlock:appearance
                                                               completionBlock:completion]];
}


+ (void)dismissNotification:(BOOL)animated {
    [[self manager] dismissNotification:animated];
}

+ (void)dismissAllNotifications:(BOOL)animated {
    [[self manager] dismissAllNotifications:animated];
}

+ (void)dismissAllNotificationsWithIdentifier:(NSString *)identifer animated:(BOOL)animated {
    [[self manager] dismissAllNotificationsWithIdentifier:identifer animated:animated];
}

+ (NSArray *)notificationIdentifiersInQueue {
    return [[self manager] notificationIdentifiersInQueue];
}

+ (NSUInteger)showingNotificationsCount {
	return [[self manager] showingNotificationsCount];
}

+ (void)relayout
{
    [[self manager] relayout];
}

+ (instancetype)manager {
    static dispatch_once_t once;
    static id sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        UIWindow *notificationWindow = [[CRToastWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        notificationWindow.backgroundColor = [UIColor clearColor];
        notificationWindow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        notificationWindow.windowLevel = UIWindowLevelStatusBar;
        notificationWindow.rootViewController = [CRToastViewController new];
        notificationWindow.rootViewController.view.clipsToBounds = YES;
        self.notificationWindow = notificationWindow;
        
        self.notifications = [@[] mutableCopy];
        self.showingNotifications = [@[] mutableCopy];
        self.operationQueue = [NSMutableArray new];
        
        self.isInLayout = NO;
        self.isLayoutRequested = NO;
    }
    return self;
}

#pragma mark - -- Notification Management --
#pragma mark - Notification Animation Blocks
#pragma mark Inward Animations
CRToastAnimationStepBlock CRToastInwardAnimationsBlock(CRToastManager *weakSelf, CRToast *notification) {
    return ^void(void) {
        notification.notificationView.frame = notification.targetFrame;
    };
}

CRToastAnimationCompletionBlock CRToastInwardAnimationsCompletionBlock(CRToastManager *weakSelf, CRToast *notification, NSString *notificationUUIDString) {
    return ^void(BOOL finished) {
        if (notification.timeInterval != DBL_MAX && notification.state == CRToastStateEntering) {
            notification.state = CRToastStateDisplaying;
            if (!notification.forceUserInteraction) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(notification.timeInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (notification.state == CRToastStateDisplaying && [notification.uuid.UUIDString isEqualToString:notificationUUIDString]) {
                        CRToastOutwardAnimationsSetupBlock(weakSelf,notification)();
                    }
                });
            }
            [weakSelf requestUpdateNotifications];
        }
    };
}

#pragma mark Outward Animations
CRToastAnimationCompletionBlock CRToastOutwardAnimationsCompletionBlock(CRToastManager *weakSelf, CRToast* notification) {
    return ^void(BOOL completed){
        if (notification.showActivityIndicator) {
            [[(CRToastView *)notification.notificationView activityIndicator] stopAnimating];
        }
        for(UIGestureRecognizer* gestureRecognizer in notification.gestureRecognizers){
            [weakSelf.notificationWindow.rootViewController.view removeGestureRecognizer:gestureRecognizer];
        }
        notification.state = CRToastStateCompleted;
        if (notification.completion) notification.completion();
        [notification.notificationView removeFromSuperview];
        [weakSelf requestUpdateNotifications];
    };
}

CRToastAnimationStepBlock CRToastOutwardAnimationsBlock(CRToastManager *weakSelf, CRToast* notification) {
    return ^{
        notification.state = CRToastStateExiting;
        [notification.animator removeAllBehaviors];
        notification.notificationView.frame = notification.targetFrame;
    };
}

CRToastAnimationStepBlock CRToastOutwardAnimationsSetupBlock(CRToastManager *weakSelf, CRToast* _notification) {
    __strong CRToast* notification = _notification;
    return ^{
        notification.state = CRToastStateExiting;
        CGRect frame = notification.notificationViewAnimationFrame2;
        if(frame.origin.x==0) frame.origin.x = notification.notificationView.frame.origin.x;
        if(frame.origin.y==0) frame.origin.y = notification.notificationView.frame.origin.y;
        notification.targetFrame = frame;
        [weakSelf.notificationWindow.rootViewController.view.gestureRecognizers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [(UIGestureRecognizer*)obj setEnabled:NO];
        }];
        
        [UIView animateWithDuration:notification.animateOutTimeInterval
                              delay:0
                            options:0
                         animations:CRToastOutwardAnimationsBlock(weakSelf, notification)
                         completion:CRToastOutwardAnimationsCompletionBlock(weakSelf, notification)];
    };
}

#pragma mark -

- (NSArray *)notificationIdentifiersInQueue {
    if (_notifications.count == 0) { return @[]; }
    return [[_notifications valueForKeyPath:@"options.kCRToastIdentifierKey"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != nil"]];
}

- (void)dismissAllNotifications:(BOOL)animated {
    [self.operationQueue addObject:^(){
        [self.notifications removeAllObjects];
    }];
    [self processOperationQueue];
}

- (void)dismissAllNotificationsWithIdentifier:(NSString *)identifer animated:(BOOL)animated {
    [self.operationQueue addObject:^(){
        if (_notifications.count == 0) { return; }
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        
        [self.notifications enumerateObjectsUsingBlock:^(CRToast *toast, NSUInteger idx, BOOL *stop) {
            NSString *toastIdentifier = toast.options[kCRToastIdentifierKey];
            if (toastIdentifier && [toastIdentifier isEqualToString:identifer]) {
                [indexes addIndex:idx];
            }
        }];
        [self.notifications removeObjectsAtIndexes:indexes];
    }];
    [self processOperationQueue];
}

- (void)addNotification:(CRToast*)notification {
    [self.operationQueue addObject:^(){
        [_notifications addObject:notification];
    }];
    [self processOperationQueue];
}

- (void)processOperationQueue {
    if(!self.isInLayout){
        if(self.operationQueue.count>0){
            void (^operation)() = self.operationQueue.firstObject;
            [self.operationQueue removeObjectAtIndex:0];
            operation();
            [self requestUpdateNotifications];
        }
    }
}

- (void)requestUpdateNotifications {
    if(self.notificationUpdateProcessed) return;
    _notificationUpdateProcessed = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.notificationUpdateProcessed = NO;
        [self _updateNotifications];
    });
}

- (void)_updateNotifications
{
    __weak __block typeof(self) weakSelf = self;
    for(__strong CRToast* notification in self.showingNotifications){
        if(![self.notifications containsObject:notification]){
            [self.showingNotifications removeObject:notification];
            if (notification.state == CRToastStateEntering || notification.state == CRToastStateDisplaying) {
                CRToastOutwardAnimationsSetupBlock(weakSelf, notification)();
            } else {
                CRToastOutwardAnimationsCompletionBlock(weakSelf, notification)(YES);
            }
            break;
        }
    }
    NSUInteger currentIndex = 0;
    for(CRToast* notification in self.notifications){
        if(++currentIndex>maxNotifications) break;
        if(![self.showingNotifications containsObject:notification]){
            [self.showingNotifications addObject:notification];
            if (notification.appearance != nil)
            {
                notification.appearance();
            }
            notification.targetFrame = CGRectZero;
            [self relayout];
            return;
        }
    }
    [self processOperationQueue];
}

- (void)relayout
{
    if(self.isInLayout){
        self.isLayoutRequested = YES;
        return;
    }
    self.isLayoutRequested = NO;
    self.isInLayout = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.showingNotificationsCount > 0){
            _notificationWindow.hidden = NO;
            CGSize notificationSize = CGSizeZero;
            CGFloat currentNotificationY = 0;
            
            for(CRToast* notification in self.showingNotifications){
                CGSize singleNotificationSize = CRNotificationViewSize(notification.notificationType, notification.preferredHeight);
                if (notification.shouldKeepNavigationBarBorder) {
                    notificationSize.height -= 1.0f;
                }
                notification.targetFrame = CGRectMake(0, currentNotificationY, singleNotificationSize.width, singleNotificationSize.height);
                notificationSize.width = MAX(notificationSize.width, singleNotificationSize.width);
                notificationSize.height += singleNotificationSize.height + 1;
                
                UIView *notificationView = notification.notificationView;
                if(!notificationView.superview){
                    notification.state = CRToastStateEntering;
                    CGRect frame = notification.notificationViewAnimationFrame1;
                    frame.origin.y += currentNotificationY;
                    notificationView.frame = frame;
                    [_notificationWindow.rootViewController.view insertSubview:notificationView atIndex:0];
                }
                
                currentNotificationY += notificationView.frame.size.height + 1;
                
                for(UIGestureRecognizer* gestureRecognizer in notification.gestureRecognizers){
                    if(![_notificationWindow.rootViewController.view.gestureRecognizers containsObject:gestureRecognizer]){
                        [_notificationWindow.rootViewController.view addGestureRecognizer:gestureRecognizer];
                    }
                }
            }
            CGRect containerFrame = CRGetNotificationContainerFrame(CRGetDeviceOrientation(), notificationSize);
            CRToast* notification = self.showingNotifications.firstObject;
            CRToastViewController *rootViewController = (CRToastViewController*)_notificationWindow.rootViewController;
            rootViewController.statusBarStyle = notification.statusBarStyle;
            rootViewController.autorotate = notification.autorotate;
            
            _notificationWindow.rootViewController.view.frame = containerFrame;
            _notificationWindow.windowLevel = notification.displayUnderStatusBar ? UIWindowLevelNormal + 1 : UIWindowLevelStatusBar;
            
            for (UIView *subview in _notificationWindow.rootViewController.view.subviews) {
                subview.userInteractionEnabled = NO;
            }
            
            _notificationWindow.rootViewController.view.userInteractionEnabled = YES;
            
            __block NSMutableArray* inwardAnimationsBlockArray = [NSMutableArray new];
            __block NSMutableArray* inwardAnimationsCompletionBlockArray = [NSMutableArray new];
            
            __weak __block typeof(self) weakSelf = self;
            for(CRToast* notification in self.showingNotifications){
                CRToastAnimationStepBlock inwardAnimationsBlock = CRToastInwardAnimationsBlock(weakSelf, notification);
                
                NSString *notificationUUIDString = notification.uuid.UUIDString;
                CRToastAnimationCompletionBlock inwardAnimationsCompletionBlock = CRToastInwardAnimationsCompletionBlock(weakSelf, notification, notificationUUIDString);
                
                [inwardAnimationsBlockArray addObject:inwardAnimationsBlock];
                [inwardAnimationsCompletionBlockArray addObject:inwardAnimationsCompletionBlock];
            }
            
            CRToastAnimationStepBlock inwardAnimationsBlock = ^{
                for(CRToastAnimationStepBlock block in inwardAnimationsBlockArray)
                    block();
            };
            CRToastAnimationCompletionBlock inwardAnimationsCompletionBlock = ^(BOOL b){
                for(__weak CRToastAnimationCompletionBlock block in inwardAnimationsCompletionBlockArray)
                    block(b);
                self.isInLayout = NO;
                if(self.isLayoutRequested || self.operationQueue.count) [self requestUpdateNotifications];
            };
            
            [UIView animateWithDuration:notification.animateInTimeInterval
                             animations:inwardAnimationsBlock
                             completion:inwardAnimationsCompletionBlock];
        }else{
            
        }
    });
}

#pragma mark - Overrides

- (NSUInteger)showingNotificationsCount {
    return self.showingNotifications.count;
}

#pragma mark - UICollisionBehaviorDelegate

- (void)collisionBehavior:(UICollisionBehavior*)behavior
      endedContactForItem:(id <UIDynamicItem>)item
   withBoundaryIdentifier:(id <NSCopying>)identifier {
    if (self.gravityAnimationCompletionBlock) {
        self.gravityAnimationCompletionBlock(YES);
    }
}

- (void)collisionBehavior:(UICollisionBehavior*)behavior
      endedContactForItem:(id <UIDynamicItem>)item1
                 withItem:(id <UIDynamicItem>)item2 {
    if (self.gravityAnimationCompletionBlock) {
        self.gravityAnimationCompletionBlock(YES);
        self.gravityAnimationCompletionBlock = NULL;
    }
}

@end
