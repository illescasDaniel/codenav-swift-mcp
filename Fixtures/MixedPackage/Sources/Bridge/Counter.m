#import "Counter.h"

@implementation Counter
- (void)incrementBy:(NSInteger)amount { _value += amount; }
- (void)reset { _value = 0; }
@end
