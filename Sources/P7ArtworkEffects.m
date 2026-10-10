#import "P7ArtworkEffects.h"
#import "P7Theme.h"
#import <CoreImage/CoreImage.h>

@implementation P7ArtworkEffects

+ (void)effectsForImage:(UIImage *)image completion:(void (^)(UIImage *, UIColor *))completion {
	if (!image) {
		completion(nil, [P7Theme tintColor]);
		return;
	}
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		UIImage *small = [self image:image scaledTo:CGSizeMake(48, 48)];
		UIImage *blurred = [self blur:small radius:5];
		UIColor *accent = [self accentFromImage:small];
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(blurred, accent);
		});
	});
}

+ (UIImage *)image:(UIImage *)image scaledTo:(CGSize)size {
	UIGraphicsBeginImageContextWithOptions(size, YES, 1);
	[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
	UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return scaled;
}

+ (UIImage *)blur:(UIImage *)image radius:(CGFloat)radius {
	static CIContext *context;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
	});
	CIImage *input = [CIImage imageWithCGImage:image.CGImage];
	CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
	[clamp setValue:input forKey:kCIInputImageKey];
	[clamp setValue:[NSValue valueWithBytes:&CGAffineTransformIdentity objCType:@encode(CGAffineTransform)] forKey:@"inputTransform"];
	CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
	[blur setValue:clamp.outputImage forKey:kCIInputImageKey];
	[blur setValue:@(radius) forKey:kCIInputRadiusKey];
	CGImageRef cg = [context createCGImage:blur.outputImage fromRect:input.extent];
	if (!cg) return image;
	UIImage *result = [UIImage imageWithCGImage:cg];
	CGImageRelease(cg);
	return result;
}

// Most saturated of a few averaged regions, adjusted to stay readable on a light background.
+ (UIColor *)accentFromImage:(UIImage *)image {
	enum { size = 4 };
	unsigned char pixels[size * size * 4];
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(pixels, size, size, 8, size * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
	CGColorSpaceRelease(space);
	if (!ctx) return [P7Theme tintColor];
	CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
	CGContextDrawImage(ctx, CGRectMake(0, 0, size, size), image.CGImage);
	CGContextRelease(ctx);

	CGFloat bestScore = -1, bestH = 0, bestS = 0, bestB = 0;
	for (int i = 0; i < size * size; i++) {
		UIColor *color = [UIColor colorWithRed:pixels[i * 4] / 255.0 green:pixels[i * 4 + 1] / 255.0 blue:pixels[i * 4 + 2] / 255.0 alpha:1];
		CGFloat h, s, b, a;
		[color getHue:&h saturation:&s brightness:&b alpha:&a];
		CGFloat score = s * (0.4 + b);
		if (score > bestScore) { bestScore = score; bestH = h; bestS = s; bestB = b; }
	}
	if (bestS < 0.18) return [UIColor colorWithWhite:0.25 alpha:1]; // grayscale art: neutral dark accent
	return [UIColor colorWithHue:bestH saturation:MAX(bestS, 0.55) brightness:MIN(MAX(bestB, 0.45), 0.72) alpha:1];
}

@end
