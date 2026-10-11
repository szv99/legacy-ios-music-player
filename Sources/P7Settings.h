#import <Foundation/Foundation.h>

extern NSString *const P7SettingsDidChangeNotification;

// Where the music comes from.
typedef NS_ENUM(NSInteger, P7Backend) {
	P7BackendDevice,     // "This iPhone": YouTube Music straight from the phone, library kept on the phone
	P7BackendServer,     // a self-hosted Player7 server (Spotify, YouTube, SoundCloud)
	P7BackendSubsonic,   // Navidrome, Airsonic, Gonic or any other Subsonic-compatible server
};

@interface P7Settings : NSObject
+ (instancetype)shared;
@property (nonatomic) P7Backend backend;           // default: Device, or Server for setups from before backends existed
@property (nonatomic, copy) NSString *serverURL;   // e.g. http://192.168.1.10:8787
@property (nonatomic, copy) NSString *token;       // stored in the keychain
@property (nonatomic) BOOL youtubeOnServer;        // the Player7 server searches and plays YouTube too (default: the phone does)
@property (nonatomic, copy) NSString *subsonicURL; // e.g. http://192.168.1.10:4533
@property (nonatomic, copy) NSString *subsonicUsername;
@property (nonatomic, copy) NSString *subsonicPassword; // stored in the keychain
@property (nonatomic, readonly) BOOL isConfigured;
@property (nonatomic) BOOL savePlayedSongs;        // played songs go straight to Offline (default YES)
@property (nonatomic, copy) NSString *discordRefreshToken; // stored in the keychain; changes don't notify
@property (nonatomic, copy) NSString *lastFMSession;       // Last.fm session key for scrobbling from the phone (keychain)
+ (NSString *)normalizedURL:(NSString *)string;    // trims, drops trailing slashes, adds http://
@end
