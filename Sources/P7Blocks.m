#import "P7Blocks.h"

@interface P7ActionSheet () <UIActionSheetDelegate>
@end

@implementation P7ActionSheet {
	NSMutableDictionary *_handlers;
	P7ActionSheet *_retainedSelf; // kept alive while on screen
}

- (instancetype)initWithTitle:(NSString *)title {
	if ((self = [super initWithTitle:title delegate:nil cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil])) {
		self.delegate = self;
		_handlers = [NSMutableDictionary new];
	}
	return self;
}

- (void)addButton:(NSString *)title handler:(void (^)(void))handler {
	NSInteger index = [self addButtonWithTitle:title];
	if (handler) _handlers[@(index)] = [handler copy];
}

- (void)addDestructiveButton:(NSString *)title handler:(void (^)(void))handler {
	[self addButton:title handler:handler];
	self.destructiveButtonIndex = self.numberOfButtons - 1;
}

- (void)showFrom:(UIViewController *)controller {
	self.cancelButtonIndex = [self addButtonWithTitle:@"Cancel"];
	_retainedSelf = self;
	UIView *view = controller.tabBarController.view ?: controller.view;
	[self showInView:view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
	void (^handler)(void) = _handlers[@(buttonIndex)];
	_retainedSelf = nil;
	if (handler) handler();
}

@end

@interface P7Alert () <UIAlertViewDelegate>
@property (nonatomic, copy) void (^confirmHandler)(P7Alert *alert);
@end

@implementation P7Alert {
	P7Alert *_retainedSelf;
}

+ (void)showError:(NSError *)error title:(NSString *)title {
	[self showMessage:error.localizedDescription ?: @"Something went wrong." title:title];
}

+ (void)showMessage:(NSString *)message title:(NSString *)title {
	[[[UIAlertView alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

+ (void)promptWithTitle:(NSString *)title message:(NSString *)message placeholder:(NSString *)placeholder confirm:(NSString *)confirm handler:(void (^)(NSString *))handler {
	P7Alert *alert = [[P7Alert alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles:confirm, nil];
	alert.delegate = alert;
	alert.alertViewStyle = UIAlertViewStylePlainTextInput;
	UITextField *field = [alert textFieldAtIndex:0];
	field.placeholder = placeholder;
	field.keyboardType = UIKeyboardTypeURL;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	alert.confirmHandler = ^(P7Alert *a) { handler([a textFieldAtIndex:0].text); };
	[alert present];
}

+ (void)loginWithTitle:(NSString *)title message:(NSString *)message confirm:(NSString *)confirm handler:(void (^)(NSString *, NSString *))handler {
	P7Alert *alert = [[P7Alert alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles:confirm, nil];
	alert.delegate = alert;
	alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
	UITextField *field = [alert textFieldAtIndex:0];
	field.placeholder = @"Username";
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	alert.confirmHandler = ^(P7Alert *a) { handler([a textFieldAtIndex:0].text, [a textFieldAtIndex:1].text); };
	[alert present];
}

+ (void)confirmWithTitle:(NSString *)title message:(NSString *)message confirm:(NSString *)confirm handler:(void (^)(void))handler {
	P7Alert *alert = [[P7Alert alloc] initWithTitle:title message:message delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles:confirm, nil];
	alert.delegate = alert;
	alert.confirmHandler = ^(P7Alert *a) { handler(); };
	[alert present];
}

- (void)present {
	_retainedSelf = self;
	[self show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
	if (buttonIndex != self.cancelButtonIndex && self.confirmHandler) self.confirmHandler(self);
	_retainedSelf = nil;
}

@end
