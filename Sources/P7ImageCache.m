#import "P7ImageCache.h"
#import "P7API.h"
#import "P7Downloads.h"
#import <objc/runtime.h>

NSString *const P7ImageCacheDidClearNotification = @"P7ImageCacheDidClearNotification";

// Bump to wipe every cover cached on the phone at the next launch.
static const NSInteger kCoverCacheVersion = 3;

@implementation P7ImageCache {
	NSCache *_memory;
	NSString *_directory;
	NSMutableDictionary *_pending; // key -> array of completion blocks
	NSURLSession *_session;
	dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
	static P7ImageCache *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_memory = [NSCache new];
		_memory.countLimit = 200;
		_pending = [NSMutableDictionary new];
		_ioQueue = dispatch_queue_create("com.szv.player7.covers", DISPATCH_QUEUE_SERIAL);
		NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
		[[NSFileManager defaultManager] removeItemAtPath:[caches stringByAppendingPathComponent:@"Covers"] error:NULL];
		_directory = [caches stringByAppendingPathComponent:@"Covers2"];
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		if ([defaults integerForKey:@"P7CoverCacheVersion"] != kCoverCacheVersion) {
			[[NSFileManager defaultManager] removeItemAtPath:_directory error:NULL];
			[defaults setInteger:kCoverCacheVersion forKey:@"P7CoverCacheVersion"];
		}
		[[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.HTTPMaximumConnectionsPerHost = 3;
		configuration.timeoutIntervalForRequest = 20;
		_session = [NSURLSession sessionWithConfiguration:configuration];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clearMemory) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
	}
	return self;
}

- (NSString *)keyForTrackID:(NSString *)trackID size:(NSInteger)size {
	return [NSString stringWithFormat:@"%@_%ld", trackID, (long)size];
}

- (NSString *)pathForKey:(NSString *)key {
	NSString *safe = [[key componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"-"];
	return [_directory stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"img"]];
}

- (UIImage *)cachedCoverForTrackID:(NSString *)trackID size:(NSInteger)size {
	if (!trackID.length) return nil;
	return [_memory objectForKey:[self keyForTrackID:trackID size:size]];
}

- (void)coverForTrackID:(NSString *)trackID size:(NSInteger)size completion:(void (^)(UIImage *))completion {
	if (!trackID.length) { completion(nil); return; }
	NSString *key = [self keyForTrackID:trackID size:size];
	UIImage *cached = [_memory objectForKey:key];
	if (cached) { completion(cached); return; }

	NSMutableArray *waiters = _pending[key];
	if (waiters) { [waiters addObject:[completion copy]]; return; }
	_pending[key] = [NSMutableArray arrayWithObject:[completion copy]];

	NSString *path = [self pathForKey:key];
	dispatch_async(_ioQueue, ^{
		UIImage *image = [self decodedImageWithData:[NSData dataWithContentsOfFile:path]];
		if (image) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self finishKey:key image:image]; });
			return;
		}
		// Offline copies keep their own cover next to the audio file.
		NSString *bareID = [trackID componentsSeparatedByString:@"|"].firstObject;
		NSData *offline = [[P7Downloads shared] coverDataForTrackID:bareID];
		image = [self decodedImageWithData:offline];
		if (image) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self finishKey:key image:image]; });
			return;
		}
		dispatch_async(dispatch_get_main_queue(), ^{ [self downloadKey:key trackID:trackID size:size path:path]; });
	});
}

- (void)downloadKey:(NSString *)key trackID:(NSString *)trackID size:(NSInteger)size path:(NSString *)path {
	NSURL *url = [[P7API shared] coverURLForTrackID:trackID size:size];
	if (!url) { [self finishKey:key image:nil]; return; }
	[[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSInteger status = [(NSHTTPURLResponse *)response statusCode];
		UIImage *image = (!error && status == 200) ? [self decodedImageWithData:data] : nil;
		if (image) [data writeToFile:path atomically:YES];
		dispatch_async(dispatch_get_main_queue(), ^{ [self finishKey:key image:image]; });
	}] resume];
}

- (void)finishKey:(NSString *)key image:(UIImage *)image {
	if (image) [_memory setObject:image forKey:key];
	NSArray *waiters = _pending[key];
	[_pending removeObjectForKey:key];
	for (void (^block)(UIImage *) in waiters) block(image);
}

// Forces decompression off the main thread so scrolling stays smooth.
- (UIImage *)decodedImageWithData:(NSData *)data {
	if (!data.length) return nil;
	UIImage *image = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
	if (!image) return nil;
	UIGraphicsBeginImageContextWithOptions(image.size, YES, image.scale);
	[image drawAtPoint:CGPointZero];
	UIImage *decoded = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return decoded ?: image;
}

- (void)clearMemory {
	[_memory removeAllObjects];
}

- (void)clearAll {
	[_memory removeAllObjects];
	NSString *directory = _directory;
	dispatch_sync(_ioQueue, ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		[fm removeItemAtPath:directory error:NULL];
		[fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
	});
	NSLog(@"[Player7] image cache cleared");
	[[NSNotificationCenter defaultCenter] postNotificationName:P7ImageCacheDidClearNotification object:self];
}

- (unsigned long long)diskBytes {
	unsigned long long total = 0;
	for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL]) {
		total += [[[NSFileManager defaultManager] attributesOfItemAtPath:[_directory stringByAppendingPathComponent:file] error:NULL] fileSize];
	}
	return total;
}

@end

static char kCoverKey;

@implementation UIImageView (P7Cover)

- (void)p7_setCoverForTrackID:(NSString *)trackID size:(NSInteger)size placeholder:(UIImage *)placeholder {
	[self p7_setCoverForTrackID:trackID size:size placeholder:placeholder whileLoading:placeholder];
}

- (void)p7_setCoverForTrackID:(NSString *)trackID size:(NSInteger)size placeholder:(UIImage *)placeholder whileLoading:(UIImage *)loading {
	NSString *key = trackID.length ? [NSString stringWithFormat:@"%@_%ld", trackID, (long)size] : nil;
	objc_setAssociatedObject(self, &kCoverKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
	UIImage *cached = [[P7ImageCache shared] cachedCoverForTrackID:trackID size:size];
	self.image = cached ?: key ? loading : placeholder;
	if (cached || !key) return;
	__weak UIImageView *weakSelf = self;
	[[P7ImageCache shared] coverForTrackID:trackID size:size completion:^(UIImage *image) {
		UIImageView *strongSelf = weakSelf;
		if (![objc_getAssociatedObject(strongSelf, &kCoverKey) isEqualToString:key]) return;
		if (image || strongSelf.image != placeholder) strongSelf.image = image ?: placeholder;
	}];
}

@end
