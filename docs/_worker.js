const contentSignal = "ai-train=yes, search=yes, ai-input=yes";
const discoveryLinks = [
  '</llms.txt>; rel="alternate"; type="text/plain"; title="LLM Documentation Index"',
  '</sitemap.xml>; rel="sitemap"; type="application/xml"',
  '</llms.txt>; rel="service-doc"; type="text/plain"; title="LLM Documentation Index"',
  '</.well-known/agent-typst/index.typ>; rel="alternate"; type="text/x-typst"; title="Typst Agent Source"',
  '</.well-known/agent-skills/index.json>; rel="index"; type="application/json"; title="Agent Skills Index"',
].join(", ");

export default {
  async fetch(request, env) {
    const responseType = agentSourceResponseType(request);
    if (responseType === null) {
      return withDiscoveryHeaders(await env.ASSETS.fetch(request), request);
    }

    const url = new URL(request.url);
    const sourcePath = sourcePathFor(url.pathname);
    if (sourcePath === null) {
      return withDiscoveryHeaders(await env.ASSETS.fetch(request), request);
    }

    const sourceResponse = await env.ASSETS.fetch(assetRequest(request, sourcePath));
    if (sourceResponse.ok) {
      return sourceTextResponseFor(
        await sourceResponse.text(),
        sourceResponse.status,
        responseType,
      );
    }

    const htmlResponse = await env.ASSETS.fetch(request);
    if (htmlResponse.status === 404) {
      const notFound = await env.ASSETS.fetch(
        assetRequest(request, "/.well-known/agent-typst/404.typ"),
      );
      if (notFound.ok) {
        return sourceTextResponseFor(await notFound.text(), 404, responseType);
      }
    }

    return withDiscoveryHeaders(htmlResponse, request);
  },
};

function agentSourceResponseType(request) {
  const accept = request.headers.get("accept")?.toLowerCase() ?? "";
  if (accept.includes("text/markdown")) {
    return "text/markdown; charset=utf-8";
  }
  if (accept.includes("text/x-typst")) {
    return "text/plain; charset=utf-8";
  }
  return null;
}

function sourcePathFor(pathname) {
  if (pathname.startsWith("/.well-known/") || pathname.includes(".")) {
    return null;
  }

  if (pathname === "/") {
    return "/.well-known/agent-typst/index.typ";
  }

  const normalizedPath = pathname.endsWith("/") ? pathname.slice(0, -1) : pathname;
  return `/.well-known/agent-typst${normalizedPath}.typ`;
}

function assetRequest(request, pathname) {
  const url = new URL(request.url);
  url.pathname = pathname;
  url.search = "";
  return new Request(url, request);
}

function sourceTextResponseFor(source, status, contentType) {
  return new Response(source, {
    status,
    headers: discoveryHeaders({
      "cache-control": "public, max-age=0, must-revalidate",
      "content-type": contentType,
      vary: "Accept",
      "x-agent-source-format": "typst",
      "x-agent-source-tokens": approximateTokenCount(source).toString(),
    }),
  });
}

function withDiscoveryHeaders(response, request) {
  const headers = discoveryHeaders(response.headers);
  if (isAgentTypstMirror(new URL(request.url).pathname)) {
    headers.set("content-type", "text/x-typst; charset=utf-8");
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function isAgentTypstMirror(pathname) {
  return pathname.startsWith("/.well-known/agent-typst/") && pathname.endsWith(".typ");
}

function discoveryHeaders(headersInit) {
  const headers = new Headers(headersInit);
  headers.set("content-signal", contentSignal);
  headers.set("link", discoveryLinks);
  return headers;
}

function approximateTokenCount(markdown) {
  const words = markdown.trim().split(/\s+/u).filter(Boolean).length;
  return Math.ceil(words * 1.35);
}
