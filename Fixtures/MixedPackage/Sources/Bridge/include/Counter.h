#import <Foundation/Foundation.h>

@protocol Resettable <NSObject>
- (void)reset;
@end

@interface Counter : NSObject <Resettable>
@property (nonatomic, readonly) NSInteger value;
- (void)incrementBy:(NSInteger)amount;
@end
