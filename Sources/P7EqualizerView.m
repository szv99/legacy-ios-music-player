#import "P7EqualizerView.h"

static const NSInteger kBarCount = 3;

@implementation P7EqualizerView {
	NSArray *_bars;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		self.userInteractionEnabled = NO;
		NSMutableArray *bars = [NSMutableArray new];
		for (NSInteger i = 0; i < kBarCount; i++) {
			CALayer *bar = [CALayer layer];
			bar.anchorPoint = CGPointMake(0.5, 1);
			bar.cornerRadius = 0.5;
			[self.layer addSublayer:bar];
			[bars addObject:bar];
		}
		_bars = bars;
		[self applyColor];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGSize size = self.bounds.size;
	CGFloat gap = MAX(1.5, size.width * 0.12);
	CGFloat width = (size.width - gap * (kBarCount - 1)) / kBarCount;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	[_bars enumerateObjectsUsingBlock:^(CALayer *bar, NSUInteger i, BOOL *stop) {
		bar.bounds = CGRectMake(0, 0, width, size.height);
		bar.position = CGPointMake(i * (width + gap) + width / 2, size.height);
	}];
	[CATransaction commit];
	[self updateAnimations];
}

- (void)setBarColor:(UIColor *)barColor {
	_barColor = barColor;
	[self applyColor];
}

- (void)tintColorDidChange {
	[super tintColorDidChange];
	[self applyColor];
}

- (void)applyColor {
	CGColorRef color = (self.barColor ?: self.tintColor).CGColor;
	for (CALayer *bar in _bars) bar.backgroundColor = color;
}

- (void)setAnimating:(BOOL)animating {
	if (_animating == animating) return;
	_animating = animating;
	[self updateAnimations];
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	// Core Animation drops animations when a view leaves the window; restart them on return.
	[self updateAnimations];
}

- (void)updateAnimations {
	static const CGFloat rest[] = {0.35, 0.6, 0.45};
	static const CFTimeInterval durations[] = {0.42, 0.55, 0.37};
	[_bars enumerateObjectsUsingBlock:^(CALayer *bar, NSUInteger i, BOOL *stop) {
		[bar removeAllAnimations];
		if (self->_animating && self.window) {
			CAKeyframeAnimation *bounce = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
			bounce.values = i == 1 ? @[@0.3, @1.0, @0.55, @0.85, @0.3] : @[@0.9, @0.25, @0.7, @0.4, @0.9];
			bounce.duration = durations[i] * 4;
			bounce.repeatCount = HUGE_VALF;
			bounce.calculationMode = kCAAnimationCubic;
			bounce.timeOffset = i * 0.2;
			[bar addAnimation:bounce forKey:@"bounce"];
		} else {
			bar.transform = CATransform3DMakeScale(1, rest[i], 1);
		}
	}];
}

@end
