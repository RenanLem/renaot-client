-- RenaOT Proxy
-- Registers a list of fallback game-server hosts with g_proxy. The client uses
-- the first reachable host, transparently. To rotate proxies for DDoS resilience
-- the operator only has to update PROXIES below and ship a new client.
--
-- Format: { host = "ip-or-hostname", port = 7172, priority = 1 }
-- Priority: lower numbers are tried first. Multiple entries with the same
-- priority are racing (whichever responds first wins).

local PROXIES = {
  -- { host = "proxy1.renaot.com", port = 7172, priority = 1 },
  -- { host = "proxy2.renaot.com", port = 7172, priority = 1 },
  -- { host = "1.2.3.4",           port = 7172, priority = 2 },
}

local MAX_ACTIVE = 2

local applied = false

function init()
  if not g_proxy then
    g_logger.warning('[renaot_proxy] g_proxy is not available in this client build — module is a no-op')
    return
  end
  if #PROXIES == 0 then
    g_logger.info('[renaot_proxy] no proxies configured — direct connection only')
    return
  end

  g_proxy.setMaxActiveProxies(MAX_ACTIVE)
  for _, p in ipairs(PROXIES) do
    g_proxy.addProxy(p.host, p.port, p.priority or 1)
  end
  applied = true
  g_logger.info(string.format('[renaot_proxy] registered %d proxy host(s)', #PROXIES))
end

function terminate()
  if applied and g_proxy then
    g_proxy.clear()
    applied = false
  end
end
