#import <Foundation/Foundation.h>

// Runs the YouTube extractor (Resources/extractor.js, or a newer copy downloaded by -checkForUpdate) in JavaScriptCore.
@interface P7Script : NSObject
+ (instancetype)shared;
// Calls extractor.<function>(arguments...) on the calling background thread (never the main thread; it blocks on the network).
// The result comes back as Foundation objects (NSDictionary / NSArray / NSString / NSNumber; JS null/undefined -> nil without error).
// A thrown JS error becomes an NSError whose localizedDescription is the error's message.
- (id)call:(NSString *)function arguments:(NSArray *)arguments error:(NSError **)error;
- (BOOL)hasFunction:(NSString *)function;
@property (nonatomic, readonly) NSString *version;   // extractor.version of the script in use
// At most once a day, in the background: downloads kP7ExtractorUpdateURL and keeps it if it loads and its version is newer.
- (void)checkForUpdate;
@end
