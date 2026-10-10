#import "P7HTTP.h"
#import <Security/Security.h>

@interface P7HTTPDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation P7HTTPDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
	[P7HTTP handleChallenge:challenge completionHandler:completionHandler];
}
@end

@implementation P7HTTP

+ (NSURLSession *)session {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.timeoutIntervalForRequest = 30;
		configuration.HTTPMaximumConnectionsPerHost = 6;
		configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
		NSOperationQueue *queue = [NSOperationQueue new];
		queue.maxConcurrentOperationCount = 1;
		session = [NSURLSession sessionWithConfiguration:configuration delegate:[P7HTTPDelegate new] delegateQueue:queue];
	});
	return session;
}

// The DER certificates in cacert.pem, parsed once.
+ (NSArray *)bundledRoots {
	static NSArray *roots;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *path = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
		NSString *pem = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
		NSMutableArray *certificates = [NSMutableArray new];
		NSString *begin = @"-----BEGIN CERTIFICATE-----", *end = @"-----END CERTIFICATE-----";
		NSScanner *scanner = pem ? [NSScanner scannerWithString:pem] : nil;
		while (scanner && [scanner scanUpToString:begin intoString:NULL] && [scanner scanString:begin intoString:NULL]) {
			NSString *base64 = nil;
			if (![scanner scanUpToString:end intoString:&base64]) break;
			NSData *der = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
			SecCertificateRef certificate = der ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der) : NULL;
			if (certificate) [certificates addObject:(__bridge_transfer id)certificate];
		}
		roots = certificates;
	});
	return roots;
}

+ (BOOL)trustIsValid:(SecTrustRef)trust {
	SecTrustResultType result = kSecTrustResultInvalid;
	return SecTrustEvaluate(trust, &result) == errSecSuccess && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
}

+ (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
	SecTrustRef trust = challenge.protectionSpace.serverTrust;
	if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] || !trust) {
		completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
		return;
	}
	if (![self trustIsValid:trust]) {
		// Add the bundled roots; the system ones still count too.
		SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)[self bundledRoots]);
		SecTrustSetAnchorCertificatesOnly(trust, false);
		if (![self trustIsValid:trust]) {
			completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
			return;
		}
	}
	completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
}

+ (NSData *)sendRequest:(NSURLRequest *)request response:(NSHTTPURLResponse **)response error:(NSError **)error {
	__block NSData *result = nil;
	__block NSURLResponse *received = nil;
	__block NSError *failure = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[[[self session] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *taskError) {
		result = data;
		received = urlResponse;
		failure = taskError;
		dispatch_semaphore_signal(done);
	}] resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	if (response) *response = [received isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)received : nil;
	if (error) *error = failure;
	return failure ? nil : (result ?: [NSData data]);
}

+ (NSData *)GET:(NSURL *)url response:(NSHTTPURLResponse **)response error:(NSError **)error {
	return [self sendRequest:[NSURLRequest requestWithURL:url] response:response error:error];
}

@end
