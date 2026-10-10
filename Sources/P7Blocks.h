#import <UIKit/UIKit.h>

// Block-based wrappers for iOS 7's delegate-based UIActionSheet and UIAlertView.

@interface P7ActionSheet : UIActionSheet
- (instancetype)initWithTitle:(NSString *)title;
- (void)addButton:(NSString *)title handler:(void (^)(void))handler;
- (void)addDestructiveButton:(NSString *)title handler:(void (^)(void))handler;
- (void)showFrom:(UIViewController *)controller;
@end

@interface P7Alert : UIAlertView
+ (void)showError:(NSError *)error title:(NSString *)title;
+ (void)showMessage:(NSString *)message title:(NSString *)title;
// Single text field prompt; handler receives the text when confirmed.
+ (void)promptWithTitle:(NSString *)title message:(NSString *)message placeholder:(NSString *)placeholder confirm:(NSString *)confirm handler:(void (^)(NSString *text))handler;
+ (void)confirmWithTitle:(NSString *)title message:(NSString *)message confirm:(NSString *)confirm handler:(void (^)(void))handler;
@end
