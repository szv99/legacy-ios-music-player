#import "P7Script.h"
#import "P7HTTP.h"
#import <JavaScriptCore/JavaScriptCore.h>

// Raw URL of Resources/extractor.js in the public repository, so YouTube fixes reach phones
// without reinstalling the app. Forks should point it at their own copy. Empty: never update.
static NSString *const kP7ExtractorUpdateURL = @"https://raw.githubusercontent.com/szv99/legacy-ios-music-player/main/Resources/extractor.js";

static NSString *const kStorageKey = @"P7ExtractorStorage";
static NSString *const kLastCheckKey = @"P7ExtractorLastUpdateCheck";
static NSString *const P7ScriptErrorDomain = @"P7ScriptErrorDomain";

@implementation P7Script {
	NSString *_source;
	NSString *_version;
	NSArray *_functions;
}

+ (instancetype)shared {
	static P7Script *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

+ (NSString *)updatedPath {
	NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
	return [[support stringByAppendingPathComponent:@"Player7"] stringByAppendingPathComponent:@"extractor.js"];
}

- (instancetype)init {
	if ((self = [super init])) {
		// P7_EXTRACTOR_PATH: development override (the macOS harness has no app bundle).
		const char *override = getenv("P7_EXTRACTOR_PATH");
		NSString *bundled = override ? @(override) : [[NSBundle mainBundle] pathForResource:@"extractor" ofType:@"js"];
		NSString *source = bundled ? [NSString stringWithContentsOfFile:bundled encoding:NSUTF8StringEncoding error:NULL] : nil;
		NSArray *functions = nil;
		NSString *version = source ? [self versionOfSource:source functions:&functions] : nil;
		if (version) {
			_source = source;
			_version = version;
			_functions = functions;
		}
		NSString *updated = override ? nil : [NSString stringWithContentsOfFile:[P7Script updatedPath] encoding:NSUTF8StringEncoding error:NULL];
		NSString *updatedVersion = updated ? [self versionOfSource:updated functions:&functions] : nil;
		if (updatedVersion && (!_version || [updatedVersion compare:_version options:NSNumericSearch] != NSOrderedAscending)) {
			_source = updated;
			_version = updatedVersion;
			_functions = functions;
		}
		if (!_source) NSLog(@"[Player7] [extractor] no usable extractor.js");
	}
	return self;
}

#pragma mark - Contexts

// A fresh context per call: calls come from many threads at once, and each context
// (with its own virtual machine) runs independently. Creating one costs a few milliseconds.
- (JSContext *)contextWithSource:(NSString *)source error:(NSError **)error {
	JSContext *context = [JSContext new];
	__block JSValue *exception = nil;
	context.exceptionHandler = ^(JSContext *ctx, JSValue *value) {
		exception = value;
	};
	[self installHostAPIInContext:context];
	[context evaluateScript:source];
	if (exception) {
		if (error) *error = [self errorFromException:exception];
		return nil;
	}
	return context;
}

- (NSString *)versionOfSource:(NSString *)source functions:(NSArray **)functions {
	JSContext *context = [self contextWithSource:source error:NULL];
	JSValue *extractor = context[@"extractor"];
	JSValue *version = extractor[@"version"];
	if (!context || ![extractor isObject] || ![version isString]) return nil;
	NSMutableArray *names = [NSMutableArray new];
	for (NSString *key in [[context evaluateScript:@"Object.keys(extractor)"] toArray]) {
		if ([extractor[key] isObject] && ![key isEqualToString:@"version"]) [names addObject:key];
	}
	if (functions) *functions = names;
	return [version toString];
}

- (NSError *)errorFromException:(JSValue *)exception {
	NSString *message = [exception isObject] && [exception[@"message"] isString] ? [exception[@"message"] toString] : [exception toString];
	NSInteger code = [exception isObject] && [exception[@"status"] isNumber] ? [[exception[@"status"] toNumber] integerValue] : 0;
	return [NSError errorWithDomain:P7ScriptErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message.length ? message : @"The YouTube extractor failed."}];
}

#pragma mark - Host API

static void P7ThrowJSError(NSString *message) {
	JSContext *context = [JSContext currentContext];
	context.exception = [JSValue valueWithNewErrorFromMessage:message inContext:context];
}

- (void)installHostAPIInContext:(JSContext *)context {
	JSValue *p7 = [JSValue valueWithNewObjectInContext:context];

	p7[@"http"] = ^id(NSDictionary *spec) {
		NSString *urlString = [spec isKindOfClass:[NSDictionary class]] ? spec[@"url"] : nil;
		NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
		if (!url) {
			P7ThrowJSError([NSString stringWithFormat:@"Bad URL: %@", urlString]);
			return nil;
		}
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
		request.HTTPMethod = [spec[@"method"] isKindOfClass:[NSString class]] ? spec[@"method"] : @"GET";
		request.timeoutInterval = [spec[@"timeout"] isKindOfClass:[NSNumber class]] ? [spec[@"timeout"] doubleValue] : 30;
		NSDictionary *headers = [spec[@"headers"] isKindOfClass:[NSDictionary class]] ? spec[@"headers"] : nil;
		for (NSString *name in headers) {
			id value = headers[name];
			if ([value isKindOfClass:[NSString class]]) [request setValue:value forHTTPHeaderField:name];
		}
		if ([spec[@"body"] isKindOfClass:[NSString class]]) request.HTTPBody = [spec[@"body"] dataUsingEncoding:NSUTF8StringEncoding];

		NSHTTPURLResponse *response = nil;
		NSError *error = nil;
		NSData *data = [P7HTTP sendRequest:request response:&response error:&error];
		if (!data) {
			P7ThrowJSError(error.localizedDescription ?: @"Network error");
			return nil;
		}
		NSMutableDictionary *responseHeaders = [NSMutableDictionary new];
		[response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop) {
			responseHeaders[name.lowercaseString] = [value description];
		}];
		NSString *body;
		if ([spec[@"responseType"] isEqual:@"hex"]) {
			// Binary bodies (e.g. the start of an audio file) as lowercase hex.
			static const char digits[] = "0123456789abcdef";
			const unsigned char *bytes = data.bytes;
			NSMutableData *hex = [NSMutableData dataWithLength:data.length * 2];
			char *out = hex.mutableBytes;
			for (NSUInteger i = 0; i < data.length; i++) {
				out[i * 2] = digits[bytes[i] >> 4];
				out[i * 2 + 1] = digits[bytes[i] & 15];
			}
			body = [[NSString alloc] initWithData:hex encoding:NSASCIIStringEncoding];
		} else {
			body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
				?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
		}
		return @{@"status": @(response.statusCode), @"headers": responseHeaders, @"body": body};
	};

	p7[@"log"] = ^(NSString *message) {
		NSLog(@"[Player7] [extractor] %@", message);
	};

	p7[@"get"] = ^id(NSString *key) {
		if (![key isKindOfClass:[NSString class]]) return [NSNull null];
		@synchronized ([P7Script class]) {
			id value = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kStorageKey][key];
			return value ?: [NSNull null];
		}
	};

	p7[@"set"] = ^(NSString *key, id value) {
		if (![key isKindOfClass:[NSString class]]) return;
		@synchronized ([P7Script class]) {
			NSMutableDictionary *storage = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kStorageKey] mutableCopy] ?: [NSMutableDictionary new];
			if ([value isKindOfClass:[NSString class]] && [value length]) storage[key] = value;
			else [storage removeObjectForKey:key];
			[[NSUserDefaults standardUserDefaults] setObject:storage forKey:kStorageKey];
		}
	};

	context[@"P7"] = p7;
}

#pragma mark - Calls

- (NSString *)version {
	@synchronized (self) { return _version; }
}

- (BOOL)hasFunction:(NSString *)function {
	@synchronized (self) { return [_functions containsObject:function]; }
}

- (id)call:(NSString *)function arguments:(NSArray *)arguments error:(NSError **)error {
	NSString *source;
	@synchronized (self) { source = _source; }
	if (!source) {
		if (error) *error = [NSError errorWithDomain:P7ScriptErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: @"The YouTube extractor is missing."}];
		return nil;
	}
	NSError *loadError = nil;
	JSContext *context = [self contextWithSource:source error:&loadError];
	if (!context) {
		if (error) *error = loadError;
		return nil;
	}
	JSValue *extractor = context[@"extractor"];
	if (![extractor[function] isObject]) {
		if (error) *error = [NSError errorWithDomain:P7ScriptErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The YouTube extractor can't %@.", function]}];
		return nil;
	}
	__block JSValue *exception = nil;
	context.exceptionHandler = ^(JSContext *ctx, JSValue *value) {
		exception = value;
	};
	JSValue *result = [extractor invokeMethod:function withArguments:arguments ?: @[]];
	if (exception) {
		if (error) *error = [self errorFromException:exception];
		return nil;
	}
	if (!result || [result isUndefined] || [result isNull]) return nil;
	return [result toObject];
}

#pragma mark - Updates

- (void)checkForUpdate {
	NSURL *url = kP7ExtractorUpdateURL.length ? [NSURL URLWithString:kP7ExtractorUpdateURL] : nil;
	if (!url) return;
	NSDate *last = [[NSUserDefaults standardUserDefaults] objectForKey:kLastCheckKey];
	if ([last isKindOfClass:[NSDate class]] && -[last timeIntervalSinceNow] < 24 * 3600) return;
	[[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:kLastCheckKey];

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		NSHTTPURLResponse *response = nil;
		NSData *data = [P7HTTP GET:url response:&response error:NULL];
		NSString *source = data && response.statusCode == 200 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
		NSArray *functions = nil;
		NSString *version = source ? [self versionOfSource:source functions:&functions] : nil;
		if (!version || [version compare:self.version ?: @"" options:NSNumericSearch] != NSOrderedDescending) return;

		NSString *path = [P7Script updatedPath];
		[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
		if (![source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return;
		@synchronized (self) {
			self->_source = source;
			self->_version = version;
			self->_functions = functions;
		}
		NSLog(@"[Player7] [extractor] updated to %@", version);
	});
}

@end
