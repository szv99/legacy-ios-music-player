#import "P7FadeImageView.h"

@implementation P7FadeImageView

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_fadeDuration = 0.25;
	}
	return self;
}

- (void)setImage:(UIImage *)image {
	if (image == self.image) return;
	if (self.window && self.image && image) {
		CATransition *fade = [CATransition animation];
		fade.type = kCATransitionFade;
		fade.duration = self.fadeDuration;
		fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
		[self.layer addAnimation:fade forKey:@"fade"];
	}
	[super setImage:image];
	if (self.imageDidChange) self.imageDidChange(image);
}

@end
