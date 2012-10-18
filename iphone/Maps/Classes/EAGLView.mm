#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGLDrawable.h>

#import "EAGLView.h"

#include "RenderBuffer.hpp"
#include "RenderContext.hpp"
#include "Framework.h"

#include "../../yg/resource_manager.hpp"
#include "../../yg/internal/opengl.hpp"
#include "../../yg/data_formats.hpp"

#include "../../map/render_policy.hpp"

#include "../../platform/platform.hpp"
#include "../../platform/video_timer.hpp"

#include "../../std/bind.hpp"

@implementation EAGLView

// You must implement this method
+ (Class)layerClass
{
  return [CAEAGLLayer class];
}

// The GL view is stored in the nib file. When it's unarchived it's sent -initWithCoder:
- (id)initWithCoder:(NSCoder*)coder
{
  if ((self = [super initWithCoder:coder]))
  {
    // Setup Layer Properties
    CAEAGLLayer * eaglLayer = (CAEAGLLayer *)self.layer;

    eaglLayer.opaque = YES;

    renderContext = shared_ptr<iphone::RenderContext>(new iphone::RenderContext());

    if (!renderContext.get())
    {
      [self release];
      return nil;
    }
    
    renderContext->makeCurrent();
    
    // ColorFormat : RGB565
    // Backbuffer : YES, (to prevent from loosing content when mixing with ordinary layers).
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithBool:NO],
                                    kEAGLDrawablePropertyRetainedBacking,
                                    kEAGLColorFormatRGB565,
                                    kEAGLDrawablePropertyColorFormat,
                                    nil];
    // Correct retina display support in opengl renderbuffer
    self.contentScaleFactor = [[UIScreen mainScreen] scale];
  }
  
  return self;
}

- (void)initRenderPolicy
{
  // to avoid grid bug on 3G device
  yg::DataFormat rtFmt = yg::Data4Bpp;
  yg::DataFormat texFmt = yg::Data4Bpp;
  if ([[NSString stringWithFormat:@"%s", glGetString(GL_RENDERER)] hasPrefix:@"PowerVR MBX"])
    rtFmt = yg::Data8Bpp;
  
  typedef void (*drawFrameFn)(id, SEL);
  SEL drawFrameSel = @selector(drawFrame);
  drawFrameFn drawFrameImpl = (drawFrameFn)[self methodForSelector:drawFrameSel];

  videoTimer = CreateIOSVideoTimer(bind(drawFrameImpl, self, drawFrameSel));
  
  yg::ResourceManager::Params rmParams;
  rmParams.m_videoMemoryLimit = GetPlatform().VideoMemoryLimit();
  rmParams.m_rtFormat = rtFmt;
  rmParams.m_texFormat = texFmt;
  
  RenderPolicy::Params rpParams;
  
  CGRect screenRect = [[UIScreen mainScreen] bounds];
  
  rpParams.m_visualScale = [[UIScreen mainScreen] scale];
    
  rpParams.m_screenWidth = screenRect.size.width * rpParams.m_visualScale;
  rpParams.m_screenHeight = screenRect.size.height * rpParams.m_visualScale;
  
  if (rpParams.m_visualScale > 1.0)
    rpParams.m_skinName = "basic_xhdpi.skn";
  else
    rpParams.m_skinName = "basic_mdpi.skn";
  
  rpParams.m_videoTimer = videoTimer;
  rpParams.m_useDefaultFB = false;
  rpParams.m_rmParams = rmParams;
  rpParams.m_primaryRC = renderContext;
  
  try
  {
    renderPolicy = CreateRenderPolicy(rpParams);
  }
  catch (yg::gl::platform_unsupported const & )
  {
    /// terminate program (though this situation is unreal :) )
  }
  
  frameBuffer = renderPolicy->GetDrawer()->screen()->frameBuffer();
  GetFramework().SetRenderPolicy(renderPolicy);
}

- (void)onSize:(int)width withHeight:(int)height
{
  frameBuffer->onSize(width, height);
  
  shared_ptr<yg::gl::Screen> screen = renderPolicy->GetDrawer()->screen();

  /// free old render buffer, as we would not create a new one.
  screen->resetRenderTarget();
  screen->resetDepthBuffer();
  renderBuffer.reset();
  
  /// detaching of old render target will occur inside beginFrame
  screen->beginFrame();
  screen->endFrame();

	/// allocate the new one
	renderBuffer = make_shared_ptr(new iphone::RenderBuffer(renderContext, (CAEAGLLayer*)self.layer));
  
  screen->setRenderTarget(renderBuffer);
  screen->setDepthBuffer(make_shared_ptr(new yg::gl::RenderBuffer(width, height, true)));

  GetFramework().OnSize(width, height);
  
  screen->beginFrame();
  screen->clear(yg::gl::Screen::s_bgColor);
  screen->endFrame();
}

- (void)drawFrame
{
	shared_ptr<PaintEvent> pe(new PaintEvent(renderPolicy->GetDrawer().get()));
  
  Framework & f = GetFramework();
  if (f.NeedRedraw())
  {
    f.SetNeedRedraw(false);
    f.BeginPaint(pe);
    f.DoPaint(pe);
    renderBuffer->present();
    f.EndPaint(pe);
  }
}

- (void)layoutSubviews
{
  if (!CGRectEqualToRect(lastViewSize, self.frame))
  {
    lastViewSize = self.frame;
    CGFloat const scale = self.contentScaleFactor;
    CGSize const s = self.bounds.size;
	  [self onSize:s.width * scale withHeight:s.height * scale];
  }
}

- (void)dealloc
{
  delete videoTimer;
  [EAGLContext setCurrentContext:nil];
  [super dealloc];
}

@end
