#import <Foundation/Foundation.h>
#import "P7Provider.h"

// "This iPhone": YouTube Music searched and played straight from the phone, no server needed.
// The YouTube work happens in the extractor script (P7Script, Resources/extractor.js), which can
// be updated without reinstalling the app; the library lives in P7LocalLibrary.
@interface P7DeviceProvider : NSObject <P7Provider>
+ (instancetype)shared;
@end
