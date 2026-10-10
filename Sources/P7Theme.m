#import "P7Theme.h"

static UIImage *P7DrawIcon(CGSize size, BOOL template, void (^draw)(CGContextRef ctx)) {
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	[[UIColor blackColor] setFill];
	[[UIColor blackColor] setStroke];
	CGContextSetLineCap(ctx, kCGLineCapRound);
	CGContextSetLineJoin(ctx, kCGLineJoinRound);
	draw(ctx);
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return template ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : image;
}

static UIImage *P7CachedIcon(NSString *key, UIImage *(^make)(void)) {
	static NSMutableDictionary *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
	UIImage *image = cache[key];
	if (!image) {
		image = make();
		if (image) cache[key] = image;
	}
	return image;
}

static void P7FillTriangle(CGContextRef ctx, CGPoint a, CGPoint b, CGPoint c) {
	CGContextMoveToPoint(ctx, a.x, a.y);
	CGContextAddLineToPoint(ctx, b.x, b.y);
	CGContextAddLineToPoint(ctx, c.x, c.y);
	CGContextClosePath(ctx);
	CGContextFillPath(ctx);
}

static void P7StrokeLine(CGContextRef ctx, CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
	CGContextMoveToPoint(ctx, x1, y1);
	CGContextAddLineToPoint(ctx, x2, y2);
	CGContextStrokePath(ctx);
}

static void P7FillRoundedRect(CGRect rect, CGFloat radius) {
	[[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius] fill];
}

@implementation P7Theme

+ (UIColor *)tintColor {
	return [UIColor colorWithRed:1.0 green:45 / 255.0 blue:85 / 255.0 alpha:1];
}

+ (UIColor *)secondaryTextColor {
	return [UIColor colorWithWhite:0.56 alpha:1];
}

+ (UIColor *)separatorColor {
	return [UIColor colorWithRed:200 / 255.0 green:199 / 255.0 blue:204 / 255.0 alpha:1];
}

+ (void)apply {
	[[UISwitch appearance] setOnTintColor:[self tintColor]];
	[[UIProgressView appearance] setProgressTintColor:[self tintColor]];
}

+ (UIImage *)placeholderArtworkWithSize:(CGFloat)size {
	NSString *key = [NSString stringWithFormat:@"placeholder-%.0f", size];
	return P7CachedIcon(key, ^UIImage *{
		return P7DrawIcon(CGSizeMake(size, size), NO, ^(CGContextRef ctx) {
			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGFloat colors[] = {0.93, 0.93, 0.95, 1, 0.83, 0.83, 0.86, 1};
			CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
			CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, size), 0);
			CGGradientRelease(gradient);
			CGColorSpaceRelease(space);

			// Centered eighth note.
			CGFloat s = size / 30.0;
			[[UIColor colorWithWhite:1 alpha:0.9] setFill];
			CGContextTranslateCTM(ctx, size * 0.5 - 15 * s * 0.6, size * 0.5 - 15 * s * 0.6);
			CGContextScaleCTM(ctx, s * 0.6, s * 0.6);
			CGContextFillEllipseInRect(ctx, CGRectMake(6, 18, 9, 7));
			CGContextFillRect(ctx, CGRectMake(13, 5, 2, 17));
			P7FillTriangle(ctx, CGPointMake(15, 5), CGPointMake(22, 10), CGPointMake(15, 10));
		});
	});
}

#pragma mark - Tab bar

+ (UIImage *)tabPlaylistsIcon {
	return P7CachedIcon(@"tab-playlists", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			P7FillRoundedRect(CGRectMake(3, 6, 15, 2), 1);
			P7FillRoundedRect(CGRectMake(3, 12, 15, 2), 1);
			P7FillRoundedRect(CGRectMake(3, 18, 11, 2), 1);
			P7FillRoundedRect(CGRectMake(3, 24, 11, 2), 1);
			CGContextFillEllipseInRect(ctx, CGRectMake(16.5, 20.5, 7, 5.5));
			CGContextFillRect(ctx, CGRectMake(22, 7, 1.8, 16));
			P7FillTriangle(ctx, CGPointMake(23.8, 7), CGPointMake(28, 10), CGPointMake(23.8, 12));
		});
	});
}

+ (UIImage *)tabSongsIcon {
	return P7CachedIcon(@"tab-songs", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			CGContextFillEllipseInRect(ctx, CGRectMake(6, 19, 10, 7.5));
			CGContextFillRect(ctx, CGRectMake(14, 4, 2, 18));
			UIBezierPath *flag = [UIBezierPath bezierPath];
			[flag moveToPoint:CGPointMake(16, 4)];
			[flag addCurveToPoint:CGPointMake(23, 13) controlPoint1:CGPointMake(18, 8) controlPoint2:CGPointMake(24, 8)];
			[flag addCurveToPoint:CGPointMake(16, 9) controlPoint1:CGPointMake(21, 10) controlPoint2:CGPointMake(18, 9)];
			[flag closePath];
			[flag fill];
		});
	});
}

+ (UIImage *)tabOfflineIcon {
	return P7CachedIcon(@"tab-offline", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			CGContextSetLineWidth(ctx, 2);
			P7StrokeLine(ctx, 15, 4, 15, 18);
			CGContextMoveToPoint(ctx, 9.5, 12.5);
			CGContextAddLineToPoint(ctx, 15, 18);
			CGContextAddLineToPoint(ctx, 20.5, 12.5);
			CGContextStrokePath(ctx);
			CGContextMoveToPoint(ctx, 5, 18);
			CGContextAddLineToPoint(ctx, 5, 25);
			CGContextAddLineToPoint(ctx, 25, 25);
			CGContextAddLineToPoint(ctx, 25, 18);
			CGContextStrokePath(ctx);
		});
	});
}

+ (UIImage *)tabSettingsIcon {
	return P7CachedIcon(@"tab-settings", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			CGContextTranslateCTM(ctx, 15, 15);
			CGContextFillEllipseInRect(ctx, CGRectMake(-9, -9, 18, 18));
			for (int i = 0; i < 8; i++) {
				CGContextSaveGState(ctx);
				CGContextRotateCTM(ctx, i * M_PI / 4);
				P7FillRoundedRect(CGRectMake(-2.25, -12.5, 4.5, 6), 1);
				CGContextRestoreGState(ctx);
			}
			CGContextSetBlendMode(ctx, kCGBlendModeClear);
			CGContextFillEllipseInRect(ctx, CGRectMake(-4, -4, 8, 8));
		});
	});
}

#pragma mark - Transport

+ (UIImage *)playIcon {
	return P7CachedIcon(@"play", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			P7FillTriangle(ctx, CGPointMake(7, 3), CGPointMake(7, 27), CGPointMake(27, 15));
		});
	});
}

+ (UIImage *)pauseIcon {
	return P7CachedIcon(@"pause", ^UIImage *{
		return P7DrawIcon(CGSizeMake(30, 30), YES, ^(CGContextRef ctx) {
			CGContextFillRect(ctx, CGRectMake(6, 4, 6, 22));
			CGContextFillRect(ctx, CGRectMake(18, 4, 6, 22));
		});
	});
}

+ (UIImage *)nextIcon {
	return P7CachedIcon(@"next", ^UIImage *{
		return P7DrawIcon(CGSizeMake(34, 22), YES, ^(CGContextRef ctx) {
			P7FillTriangle(ctx, CGPointMake(2, 2), CGPointMake(2, 20), CGPointMake(15, 11));
			P7FillTriangle(ctx, CGPointMake(15, 2), CGPointMake(15, 20), CGPointMake(28, 11));
			CGContextFillRect(ctx, CGRectMake(28, 2, 3, 18));
		});
	});
}

+ (UIImage *)previousIcon {
	return P7CachedIcon(@"previous", ^UIImage *{
		return P7DrawIcon(CGSizeMake(34, 22), YES, ^(CGContextRef ctx) {
			CGContextFillRect(ctx, CGRectMake(3, 2, 3, 18));
			P7FillTriangle(ctx, CGPointMake(19, 2), CGPointMake(19, 20), CGPointMake(6, 11));
			P7FillTriangle(ctx, CGPointMake(32, 2), CGPointMake(32, 20), CGPointMake(19, 11));
		});
	});
}

+ (UIImage *)smallPlayIcon {
	return P7CachedIcon(@"small-play", ^UIImage *{
		return P7DrawIcon(CGSizeMake(20, 20), YES, ^(CGContextRef ctx) {
			P7FillTriangle(ctx, CGPointMake(5, 2), CGPointMake(5, 18), CGPointMake(18, 10));
		});
	});
}

+ (UIImage *)smallPauseIcon {
	return P7CachedIcon(@"small-pause", ^UIImage *{
		return P7DrawIcon(CGSizeMake(20, 20), YES, ^(CGContextRef ctx) {
			CGContextFillRect(ctx, CGRectMake(4, 3, 4, 14));
			CGContextFillRect(ctx, CGRectMake(12, 3, 4, 14));
		});
	});
}

+ (UIImage *)smallNextIcon {
	return P7CachedIcon(@"small-next", ^UIImage *{
		return P7DrawIcon(CGSizeMake(24, 16), YES, ^(CGContextRef ctx) {
			P7FillTriangle(ctx, CGPointMake(1, 1), CGPointMake(1, 15), CGPointMake(11, 8));
			P7FillTriangle(ctx, CGPointMake(11, 1), CGPointMake(11, 15), CGPointMake(21, 8));
			CGContextFillRect(ctx, CGRectMake(21, 1, 2, 14));
		});
	});
}

+ (UIImage *)shuffleIcon {
	return P7CachedIcon(@"shuffle", ^UIImage *{
		return P7DrawIcon(CGSizeMake(26, 20), YES, ^(CGContextRef ctx) {
			CGContextSetLineWidth(ctx, 1.8);
			CGContextMoveToPoint(ctx, 1, 5);
			CGContextAddLineToPoint(ctx, 6, 5);
			CGContextAddCurveToPoint(ctx, 12, 5, 12, 15, 18, 15);
			CGContextAddLineToPoint(ctx, 23, 15);
			CGContextMoveToPoint(ctx, 1, 15);
			CGContextAddLineToPoint(ctx, 6, 15);
			CGContextAddCurveToPoint(ctx, 12, 15, 12, 5, 18, 5);
			CGContextAddLineToPoint(ctx, 23, 5);
			CGContextStrokePath(ctx);
			P7FillTriangle(ctx, CGPointMake(21, 1.5), CGPointMake(21, 8.5), CGPointMake(25.5, 5));
			P7FillTriangle(ctx, CGPointMake(21, 11.5), CGPointMake(21, 18.5), CGPointMake(25.5, 15));
		});
	});
}

static void P7DrawRepeat(CGContextRef ctx) {
	CGContextSetLineWidth(ctx, 1.8);
	UIBezierPath *loop = [UIBezierPath bezierPath];
	[loop moveToPoint:CGPointMake(17, 4)];
	[loop addLineToPoint:CGPointMake(7, 4)];
	[loop addArcWithCenter:CGPointMake(7, 9) radius:5 startAngle:-M_PI_2 endAngle:M_PI_2 clockwise:NO];
	[loop moveToPoint:CGPointMake(9, 14)];
	[loop addLineToPoint:CGPointMake(19, 14)];
	[loop addArcWithCenter:CGPointMake(19, 9) radius:5 startAngle:M_PI_2 endAngle:-M_PI_2 clockwise:NO];
	loop.lineWidth = 1.8;
	[loop stroke];
	P7FillTriangle(ctx, CGPointMake(15, 0.5), CGPointMake(15, 7.5), CGPointMake(19.5, 4));
	P7FillTriangle(ctx, CGPointMake(11, 10.5), CGPointMake(11, 17.5), CGPointMake(6.5, 14));
}

+ (UIImage *)repeatIcon {
	return P7CachedIcon(@"repeat", ^UIImage *{
		return P7DrawIcon(CGSizeMake(26, 20), YES, ^(CGContextRef ctx) {
			P7DrawRepeat(ctx);
		});
	});
}

+ (UIImage *)repeatOneIcon {
	return P7CachedIcon(@"repeat-one", ^UIImage *{
		return P7DrawIcon(CGSizeMake(26, 20), YES, ^(CGContextRef ctx) {
			P7DrawRepeat(ctx);
			NSDictionary *attributes = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:7], NSForegroundColorAttributeName: [UIColor blackColor]};
			[@"1" drawAtPoint:CGPointMake(11, 4.5) withAttributes:attributes];
		});
	});
}

+ (UIImage *)queueIcon {
	return P7CachedIcon(@"queue", ^UIImage *{
		return P7DrawIcon(CGSizeMake(24, 18), YES, ^(CGContextRef ctx) {
			for (int i = 0; i < 3; i++) {
				CGFloat y = 2.5 + i * 6;
				CGContextFillEllipseInRect(ctx, CGRectMake(1, y - 1.5, 3, 3));
				P7FillRoundedRect(CGRectMake(7, y - 0.9, 16, 1.8), 0.9);
			}
		});
	});
}

+ (UIImage *)chevronDownIcon {
	return P7CachedIcon(@"chevron-down", ^UIImage *{
		return P7DrawIcon(CGSizeMake(24, 14), YES, ^(CGContextRef ctx) {
			CGContextSetLineWidth(ctx, 2.5);
			CGContextMoveToPoint(ctx, 3, 3);
			CGContextAddLineToPoint(ctx, 12, 11);
			CGContextAddLineToPoint(ctx, 21, 3);
			CGContextStrokePath(ctx);
		});
	});
}

+ (UIImage *)moreIcon {
	return P7CachedIcon(@"more", ^UIImage *{
		return P7DrawIcon(CGSizeMake(24, 6), YES, ^(CGContextRef ctx) {
			for (int i = 0; i < 3; i++) CGContextFillEllipseInRect(ctx, CGRectMake(2 + i * 8, 1, 4, 4));
		});
	});
}

+ (UIImage *)downloadIcon {
	return P7CachedIcon(@"download", ^UIImage *{
		return P7DrawIcon(CGSizeMake(22, 22), YES, ^(CGContextRef ctx) {
			CGContextSetLineWidth(ctx, 1.2);
			CGContextStrokeEllipseInRect(ctx, CGRectMake(1.5, 1.5, 19, 19));
			CGContextSetLineWidth(ctx, 1.5);
			P7StrokeLine(ctx, 11, 6, 11, 15);
			CGContextMoveToPoint(ctx, 7.5, 11.5);
			CGContextAddLineToPoint(ctx, 11, 15);
			CGContextAddLineToPoint(ctx, 14.5, 11.5);
			CGContextStrokePath(ctx);
		});
	});
}

+ (UIImage *)downloadedIcon {
	return P7CachedIcon(@"downloaded", ^UIImage *{
		return P7DrawIcon(CGSizeMake(22, 22), YES, ^(CGContextRef ctx) {
			CGContextFillEllipseInRect(ctx, CGRectMake(1, 1, 20, 20));
			CGContextSetBlendMode(ctx, kCGBlendModeClear);
			CGContextSetLineWidth(ctx, 1.8);
			CGContextMoveToPoint(ctx, 6.5, 11);
			CGContextAddLineToPoint(ctx, 9.5, 14.5);
			CGContextAddLineToPoint(ctx, 15.5, 7.5);
			CGContextStrokePath(ctx);
		});
	});
}

+ (UIImage *)speakerIcon {
	return P7CachedIcon(@"speaker", ^UIImage *{
		return P7DrawIcon(CGSizeMake(14, 14), YES, ^(CGContextRef ctx) {
			CGContextFillRect(ctx, CGRectMake(1, 5, 3, 4));
			P7FillTriangle(ctx, CGPointMake(3, 5), CGPointMake(8, 1), CGPointMake(8, 13));
			CGContextFillRect(ctx, CGRectMake(3, 5, 2, 4));
		});
	});
}

@end
