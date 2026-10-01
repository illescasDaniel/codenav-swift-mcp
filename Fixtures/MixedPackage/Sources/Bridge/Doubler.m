#import "Counter.h"

@interface Doubler : Counter
@end

@implementation Doubler
- (void)incrementBy:(NSInteger)amount { [super incrementBy:amount * 2]; }
@end
