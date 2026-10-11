#import <UIKit/UIKit.h>

extern NSString *const P7DiscordDidChangeNotification;   // account or setting changed

// Shows the song that's playing on the user's Discord profile ("Listening to …"), straight
// from the phone, whatever the music source.
//
// Linking uses Discord's sign-in for devices without a keyboard: the app shows a QR code and a
// short code, the user approves it at discord.com/activate on another device, and the app gets
// a token. The status itself is a Discord Social SDK "headless session". Every request goes to
// gaming-sdk.com, because discord.com only accepts encryption that iOS 7 doesn't have.
@interface P7Discord : NSObject
+ (instancetype)shared;
- (void)start;

@property (nonatomic, readonly) BOOL available;          // this build has a Discord application id
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly, copy) NSString *username;
@property (nonatomic) BOOL enabled;                      // "Show on Discord" switch, default on

// Linking, on the main thread. requestCode hands over {code, url} to show; waitForApproval
// calls back with nil once the user approved, or with an error when the code was declined
// or expired. stopWaiting cancels it.
- (void)requestCode:(void (^)(NSDictionary *code, NSError *error))completion;
- (void)waitForApproval:(NSDictionary *)code completion:(void (^)(NSError *error))completion;
- (void)stopWaiting;
- (void)disconnect;
@end
