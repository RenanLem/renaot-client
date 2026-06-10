local splashOverlay = nil
local destroyEvent = nil
local fadeOutEvent = nil

local SHOW_MS = 2500
local FADE_MS = 600

function init()
  g_ui.importStyle('splash.otui')

  splashOverlay = g_ui.createWidget('SplashOverlay', rootWidget)
  if not splashOverlay then
    g_logger.error('[renaot_splash] failed to create SplashOverlay widget')
    return
  end
  splashOverlay:addAnchor(AnchorTop,    'parent', AnchorTop)
  splashOverlay:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  splashOverlay:addAnchor(AnchorLeft,   'parent', AnchorLeft)
  splashOverlay:addAnchor(AnchorRight,  'parent', AnchorRight)
  splashOverlay:raise()
  splashOverlay:setOpacity(0)

  g_effects.fadeIn(splashOverlay, FADE_MS)

  fadeOutEvent = scheduleEvent(function()
    fadeOutEvent = nil
    if not splashOverlay then return end
    g_effects.fadeOut(splashOverlay, FADE_MS)
    destroyEvent = scheduleEvent(function()
      destroyEvent = nil
      if splashOverlay then
        splashOverlay:destroy()
        splashOverlay = nil
      end
    end, FADE_MS + 50)
  end, SHOW_MS)
end

function terminate()
  if fadeOutEvent then removeEvent(fadeOutEvent); fadeOutEvent = nil end
  if destroyEvent then removeEvent(destroyEvent); destroyEvent = nil end
  if splashOverlay then
    splashOverlay:destroy()
    splashOverlay = nil
  end
end
