//
//  ViewController.m
//  ImageFFT
//
//  Created by Adland Lee on 8/18/14.
//  Copyright (c) 2014 Adland Lee. All rights reserved.
//

#import "ImageFFTViewController.h"

#import "FFT2D.h"

#import <Accelerate/Accelerate.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>

@interface ImageFFTViewController () {
    UIView * flashView;

    CIContext * _CIContext;
    EAGLContext* _EAGLContext;
    
    NSString* _sessionPreset;
    
    CVOpenGLESTextureCacheRef _videoTextureCache;
    
    CGFloat _effectiveScale;
}

@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t FFTQueue;

@property (nonatomic) AVCaptureSession *session;
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic, readonly, getter = isSessionRunningAndDeviceAuthorized) BOOL sessionRunningAndDeviceAuthorized;

@property AVCaptureStillImageOutput * stillImageOutput;

@property CGRect primaryViewerBounds;
@property CGRect secondaryViewerBounds;
@property FFT2D * aFFT2D;

@end

@implementation ImageFFTViewController

static void * AVCaptureStillImageIsCapturingStillImageContext = &AVCaptureStillImageIsCapturingStillImageContext;

- (BOOL)isSessionRunningAndDeviceAuthorized
{
    return [self.session isRunning] && [self isDeviceAuthorized];
}

+ (NSSet *)keyPathsForValuesAffectingSessionRunningAndDeviceAuthorized
{
    return [NSSet setWithObjects:@"session.running", @"deviceAuthorized", nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.session = [[AVCaptureSession alloc] init];

    // Check for device authorization
    [self checkDeviceAuthorizationStatus];

    _EAGLContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    
    _CIContext = [CIContext contextWithEAGLContext:_EAGLContext options:@{kCIContextOutputColorSpace: [NSNull null]} ];
    
    if (! _EAGLContext) {
        NSLog(@"Failed to create ES context");
    }
    
    GLKView * view = (GLKView *)self.view;
    view.context = _EAGLContext;
    
//    self.preferredFramesPerSecond = 60;
    
    view.contentScaleFactor = [UIScreen mainScreen].scale;
    
    _sessionPreset = AVCaptureSessionPreset352x288;
    
    CGFloat width = view.frame.size.width * view.contentScaleFactor;
    CGFloat height = view.frame.size.height * view.contentScaleFactor;
    
    self.primaryViewerBounds = (CGRect){
        0
        , height - width
        , width
        , width
    };
    
    secondaryViewerBounds = (CGRect){
        0.5f * view.frame.size.width
        , 0.25f * view.frame.size.width
        , view.frame.size.width
        , view.frame.size.width
    };
    
    self.sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);

    [self setupFFTAnalysis];
    [self setupGL];
    [self setupAVCapture];
}

- (BOOL)prefersStatusBarHidden
{
    return true;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

- (void) setupGL
{
    [EAGLContext setCurrentContext:_EAGLContext];
}

- (void) setupAVCapture
{
    dispatch_async(self.sessionQueue, ^{
    #if COREVIDEO_USE_EAGLCONTEXT_CLASS_IN_API
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _EAGLContext, NULL, &_videoTextureCache);
    #else
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)_context, NULL, &_videoTextureCache);
    #endif
        if (err)
        {
            NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
            return;
        }
        
        [_session beginConfiguration];
        
        [_session setSessionPreset:_sessionPreset];
        
        AVCaptureDevice* videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (nil == videoDevice) assert(0);
        NSError* error;
        AVCaptureDeviceInput* videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        if (error) assert(0);
        [_session addInput:videoDeviceInput];
        

        self.stillImageOutput = [AVCaptureStillImageOutput new];
        [self.stillImageOutput addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:AVCaptureStillImageIsCapturingStillImageContext];
        [_session addOutput:self.stillImageOutput];
        

        AVCaptureVideoDataOutput* videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        [videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
        [videoDataOutput setVideoSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            }
         ];
        [videoDataOutput setSampleBufferDelegate:self queue:self.sessionQueue];
        [_session addOutput:videoDataOutput];

        _effectiveScale = 1.0;

        [_session commitConfiguration];
        
        [_session startRunning];
    });
}

- (void) setupFFTAnalysis
{
    CGRect bounds = {0,0, 256,256};
    
    self.aFFT2D = [FFT2D FFT2DWithBounds:bounds context:_CIContext];
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	fromConnection:(AVCaptureConnection *)connection
{
    if (! _videoTextureCache) {
        NSLog(@"No video texture cache");
        return;
    }

    [connection setVideoOrientation:AVCaptureVideoOrientationPortrait];

    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    CIImage * image = [CIImage imageWithCVPixelBuffer:imageBuffer];
    
    image = [self filterImage:image];

    CIImage * drawImage = [self.aFFT2D FFTWithCIImage:image];
    
    CGRect sourceRect = drawImage.extent;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [_CIContext drawImage:image inRect:self.secondaryViewerBounds fromRect:sourceRect];
        [_CIContext drawImage:drawImage inRect:self.primaryViewerBounds fromRect:sourceRect];

        [(GLKView *)self.view display];
    });
    
    [self cleanUpTextures];
}

/**
 Create a CIImage from sample buffer data
 */
- (CIImage *) filterImage:(CIImage *)image
{
    image = [self filterSquareImage:image];
    image = [self filterGrayscaleImage:image];
    image = [self filterScaleImage:image fromSize:image.extent.size.width toSize:256];

    return image;
}

- (CIImage *) filterSquareImage:(CIImage *)inImage
{

    // crop to square
    CGRect cropRect = inImage.extent;
    
    if (cropRect.size.width == cropRect.size.height) {
        return inImage;
    }

    if (cropRect.size.width < cropRect.size.height) {
        cropRect.size.height = cropRect.size.width;
    }
    else {
        cropRect.size.width = cropRect.size.height;
    }
    
    return [CIFilter filterWithName:@"CICrop" keysAndValues:
        kCIInputImageKey, inImage
        , @"inputRectangle", [CIVector vectorWithCGRect:cropRect]
        , nil].outputImage;
}

- (CIImage *) filterGrayscaleImage:(CIImage *)inImage
{
    return [CIFilter filterWithName:@"CIMaximumComponent"
        keysAndValues:
            kCIInputImageKey, inImage
            , nil
        ].outputImage;
}

- (CIImage *) filterScaleImage:(CIImage *)inImage fromSize:(Float32)fromSize toSize:(Float32)toSize
{
    Float32 scale = toSize / fromSize;
    
    return [CIFilter filterWithName:@"CILanczosScaleTransform"
                         keysAndValues:
               kCIInputImageKey, inImage
               , @"inputScale", [NSNumber numberWithFloat:scale]
               , nil
               ].outputImage;
}


- (void) cleanUpTextures
{
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);
}

// utility routing used during image capture to set up capture orientation
- (AVCaptureVideoOrientation)avOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation
{
    AVCaptureVideoOrientation result = (AVCaptureVideoOrientation)deviceOrientation;
    if ( deviceOrientation == UIDeviceOrientationLandscapeLeft )
        result = AVCaptureVideoOrientationLandscapeRight;
    else if ( deviceOrientation == UIDeviceOrientationLandscapeRight )
        result = AVCaptureVideoOrientationLandscapeLeft;
    return result;
}

// utility routine to display error aleart if takePicture fails
- (void)displayErrorOnMainQueue:(NSError *)error withMessage:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%d)", message, (int)[error code]]
                                                            message:[error localizedDescription]
                                                           delegate:nil
                                                  cancelButtonTitle:@"Dismiss"
                                                  otherButtonTitles:nil];
        [alertView show];
    });
}

- (IBAction)takePicture:(id)sender
{
    AVCaptureConnection * stillImageConnection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    UIDeviceOrientation currentDeviceOrientation = [[UIDevice currentDevice] orientation];
    AVCaptureVideoOrientation avCaptureOrientation = [self avOrientationForDeviceOrientation:currentDeviceOrientation];
    
    [stillImageConnection setVideoOrientation:avCaptureOrientation];
    [stillImageConnection setVideoScaleAndCropFactor:_effectiveScale];
    
    [self.stillImageOutput setOutputSettings:@{
        AVVideoCodecKey : AVVideoCodecJPEG
        }];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:stillImageConnection completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError * error) {
        if (error) {
            [self displayErrorOnMainQueue:error withMessage:@"Take picture failed"];
        }
        else {
            NSData * jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
            CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, imageDataSampleBuffer, kCMAttachmentMode_ShouldPropagate);
            ALAssetsLibrary * library = [ALAssetsLibrary new];
            [library writeImageDataToSavedPhotosAlbum:jpegData metadata:(__bridge id)attachments completionBlock:^(NSURL *assetURL, NSError *error) {
                if (error) {
                    [self displayErrorOnMainQueue:error withMessage:@"Save to camera roll failed"];
                }
            }];
            
            if (attachments) {
                CFRelease(attachments);
            }
        }
    }];
}

// perform a flash bulb animation using KVO to monitor the value of the capturingStillImage property of the AVCaptureStillImageOutput class
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == AVCaptureStillImageIsCapturingStillImageContext ) {
        BOOL isCapturingStillImage = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        
        if ( isCapturingStillImage ) {
            // do flash bulb like animation
            flashView = [[UIView alloc] initWithFrame:self.view.frame];
            [flashView setBackgroundColor:[UIColor whiteColor]];
            [flashView setAlpha:0.f];
            [[[self view] window] addSubview:flashView];
            
            [UIView animateWithDuration:.4f
                             animations:^{
                                 [flashView setAlpha:1.f];
                             }
             ];
        }
        else {
            [UIView animateWithDuration:.4f
                             animations:^{
                                 [flashView setAlpha:0.f];
                             }
                             completion:^(BOOL finished){
                                 [flashView removeFromSuperview];
                                 //                                 [flashView release];
                                 flashView = nil;
                             }
             ];
        }
    }
}

- (void) checkDeviceAuthorizationStatus
{
    NSString * mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        NSLog(granted ? @"YES" : @"NO");
        if (granted) {
            self.deviceAuthorized = YES;
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[[UIAlertView alloc] initWithTitle:@"ImageFFT!" message:@"ImageFFT does not have permission to use Camera, please change privacy settings" delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                self.deviceAuthorized = NO;
            });
        }
    }];
}


@end
