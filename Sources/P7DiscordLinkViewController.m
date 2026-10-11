#import "P7DiscordLinkViewController.h"
#import "P7Discord.h"
#import "P7Blocks.h"
#import "P7Theme.h"
#import <CoreImage/CoreImage.h>

@implementation P7DiscordLinkViewController {
	UILabel *_scanLabel;
	UIImageView *_qrView;
	UILabel *_orLabel;
	UILabel *_codeLabel;
	UIActivityIndicatorView *_spinner;
	UILabel *_statusLabel;
	UIButton *_retryButton;
	BOOL _closed;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Connect Discord";
	self.view.backgroundColor = [UIColor whiteColor];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];

	_scanLabel = [self labelWithFont:[UIFont systemFontOfSize:17] color:[UIColor blackColor]];
	_scanLabel.text = @"Scan with your phone's camera";
	_qrView = [UIImageView new];
	[self.view addSubview:_qrView];
	_orLabel = [self labelWithFont:[UIFont systemFontOfSize:15] color:[P7Theme secondaryTextColor]];
	_orLabel.text = @"or go to discord.com/activate on any device and enter";
	_codeLabel = [self labelWithFont:[UIFont fontWithName:@"Menlo-Bold" size:30] ?: [UIFont boldSystemFontOfSize:30] color:[UIColor blackColor]];
	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
	[self.view addSubview:_spinner];
	_statusLabel = [self labelWithFont:[UIFont systemFontOfSize:15] color:[P7Theme secondaryTextColor]];
	_retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_retryButton.titleLabel.font = [UIFont systemFontOfSize:17];
	[_retryButton setTitle:@"Get a New Code" forState:UIControlStateNormal];
	[_retryButton addTarget:self action:@selector(requestCode) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:_retryButton];
	[self requestCode];
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
	UILabel *label = [UILabel new];
	label.font = font;
	label.textColor = color;
	label.textAlignment = NSTextAlignmentCenter;
	label.numberOfLines = 0;
	[self.view addSubview:label];
	return label;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	CGFloat width = self.view.bounds.size.width;
	CGFloat textWidth = width - 40;
	// The QR code shrinks on 3.5-inch screens so everything fits.
	CGFloat side = MIN(220, self.view.bounds.size.height - self.topLayoutGuide.length - 250);
	CGFloat y = self.topLayoutGuide.length + 20;
	_scanLabel.frame = CGRectMake(20, y, textWidth, 22);
	y += 32;
	_qrView.frame = CGRectMake(round((width - side) / 2), y, side, side);
	y += side + 16;
	CGSize orSize = [_orLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
	_orLabel.frame = CGRectMake(20, y, textWidth, ceil(orSize.height));
	y += ceil(orSize.height) + 8;
	_codeLabel.frame = CGRectMake(20, y, textWidth, 38);
	y += 54;
	_spinner.center = CGPointMake(width / 2, y + 10);
	_statusLabel.frame = CGRectMake(20, y + (_spinner.isAnimating ? 28 : 0), textWidth, 40);
	_retryButton.frame = CGRectMake(20, CGRectGetMaxY(_statusLabel.frame) + 4, textWidth, 36);
}

- (void)showStatus:(NSString *)status waiting:(BOOL)waiting failed:(BOOL)failed {
	waiting ? [_spinner startAnimating] : [_spinner stopAnimating];
	_statusLabel.text = status;
	_retryButton.hidden = !failed;
	[self.view setNeedsLayout];
}

- (void)requestCode {
	_qrView.alpha = 0.15;
	_codeLabel.text = nil;
	[self showStatus:@"Getting a code…" waiting:YES failed:NO];
	[[P7Discord shared] requestCode:^(NSDictionary *code, NSError *error) {
		if (self->_closed) return;
		if (error) {
			[self showStatus:error.localizedDescription waiting:NO failed:YES];
			return;
		}
		self->_qrView.image = [self QRCodeFor:code[@"url"] side:440];
		self->_qrView.alpha = 1;
		self->_codeLabel.text = code[@"code"];
		[self showStatus:@"Waiting for you to approve…" waiting:YES failed:NO];
		[[P7Discord shared] waitForApproval:code completion:^(NSError *waitError) {
			if (waitError) {
				self->_qrView.alpha = 0.15;
				[self showStatus:waitError.localizedDescription waiting:NO failed:YES];
				return;
			}
			[self dismissViewControllerAnimated:YES completion:^{
				[P7Alert showMessage:@"Your Discord profile now shows the song you're playing." title:[NSString stringWithFormat:@"Connected as %@", [P7Discord shared].username]];
			}];
		}];
	}];
}

- (void)cancel {
	_closed = YES;
	[[P7Discord shared] stopWaiting];
	[self dismissViewControllerAnimated:YES completion:nil];
}

// Black modules on white, with the quiet zone around them that scanners need, scaled up
// without smoothing so the edges stay sharp.
- (UIImage *)QRCodeFor:(NSString *)text side:(CGFloat)side {
	CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
	[filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
	[filter setValue:@"M" forKey:@"inputCorrectionLevel"];
	CIImage *output = filter.outputImage;
	if (!output) return nil;
	CGImageRef modules = [[CIContext contextWithOptions:nil] createCGImage:output fromRect:output.extent];
	if (!modules) return nil;
	CGFloat count = output.extent.size.width;
	CGFloat module = floor(side / (count + 8));
	CGFloat inset = round((side - module * count) / 2);
	UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 1);
	CGContextRef context = UIGraphicsGetCurrentContext();
	[[UIColor whiteColor] setFill];
	CGContextFillRect(context, CGRectMake(0, 0, side, side));
	CGContextSetInterpolationQuality(context, kCGInterpolationNone);
	CGContextTranslateCTM(context, 0, side);
	CGContextScaleCTM(context, 1, -1);
	CGContextDrawImage(context, CGRectMake(inset, inset, module * count, module * count), modules);
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	CGImageRelease(modules);
	return image;
}

@end
