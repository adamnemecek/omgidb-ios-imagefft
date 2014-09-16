//
//  FFT2D.h
//  ImageFFT
//
//  Created by Adland Lee on 9/8/14.
//  Copyright (c) 2014 Adland Lee. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface FFT2D : NSObject

+ (instancetype) FFT2DWithBounds:(CGRect)bounds;
+ (instancetype) FFT2DWithBounds:(CGRect)bounds context:(CIContext *)context;
+ (instancetype) FFT2DWithImage:(CIImage *)image;
+ (instancetype) FFT2DWithImage:(CIImage *)image context:(CIContext *)context;

- (id) init;
- (id) initWithBounds:(CGRect)bounds;
- (id) initWithBounds:(CGRect)bounds context:(CIContext *)context;
- (id) initWithImage:(CIImage *)image;
- (id) initWithImage:(CIImage *)image context:(CIContext *)context;

@property (nonatomic) CIContext * ciContext;

- (void) reinitWithBounds:(CGRect)bounds;
- (void) reinitWithImage:(CIImage *)image;

- (CIImage *) FFTWithCGImage:(CGImageRef)image;

- (CIImage *) FFTWithCIImage:(CIImage *)image;
- (CIImage *) FFTWithCIImage:(CIImage *)image context:(CIContext *)context;

@end
