import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";
import mcpTheme from "./theme";

// Site configuration
export const SITE_URL = "https://muhammad-fiaz.github.io/mcp.zig";
export const SITE_NAME = "MCP.zig";
export const SITE_DESCRIPTION =
  "The first comprehensive Model Context Protocol (MCP) library for Zig — build MCP servers and clients with tools, resources, prompts, STDIO/HTTP transport, JSON-RPC 2.0, and native Zig performance.";

// Google Analytics and Google Tag Manager IDs
export const GA_ID = "G-6BVYCRK57P";
export const GTM_ID = "GTM-P4M9T8ZR";

// Google AdSense Client ID
export const ADSENSE_CLIENT_ID = "ca-pub-2040560600290490";

// SEO Keywords
export const KEYWORDS =
  "zig, mcp, model context protocol, ai, llm, tools, resources, prompts, zig library, json-rpc, mcp server, mcp client, stdio transport, http transport, ai integration, zig mcp, mcp zig, agent, ai agent, function calling, structured output, ziglang";

export default defineConfig({
  lang: "en-US",
  title: "Model Context Protocol (MCP) Library for Zig",
  titleTemplate: "%s | MCP.zig",
  description: SITE_DESCRIPTION,
  base: "/mcp.zig/",
  lastUpdated: true,
  cleanUrls: true,

  sitemap: {
    hostname: SITE_URL,
  },

  vite: {
    plugins: [llmstxt()],
  },

  head: [
    [
      "meta",
      { name: "viewport", content: "width=device-width, initial-scale=1.0" },
    ],
    ["meta", { name: "google-adsense-account", content: ADSENSE_CLIENT_ID }],
    // Primary Meta Tags
    ["meta", { name: "title", content: SITE_NAME }],
    ["meta", { name: "description", content: SITE_DESCRIPTION }],
    ["meta", { name: "keywords", content: KEYWORDS }],
    ["meta", { name: "author", content: "Muhammad Fiaz" }],
    ["meta", { name: "robots", content: "index, follow" }],
    ["meta", { name: "language", content: "English" }],
    ["meta", { name: "revisit-after", content: "7 days" }],
    ["meta", { name: "generator", content: "VitePress" }],

    // Open Graph / Facebook
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:url", content: SITE_URL }],
    ["meta", { property: "og:title", content: SITE_NAME }],
    ["meta", { property: "og:description", content: SITE_DESCRIPTION }],
    ["meta", { property: "og:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { property: "og:image:width", content: "1200" }],
    ["meta", { property: "og:image:height", content: "630" }],
    [
      "meta",
      {
        property: "og:image:alt",
        content: "MCP.zig - Model Context Protocol Library for Zig",
      },
    ],
    ["meta", { property: "og:site_name", content: SITE_NAME }],
    ["meta", { property: "og:locale", content: "en_US" }],

    // Twitter Card
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
    ["meta", { name: "twitter:url", content: SITE_URL }],
    ["meta", { name: "twitter:title", content: SITE_NAME }],
    ["meta", { name: "twitter:description", content: SITE_DESCRIPTION }],
    ["meta", { name: "twitter:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { name: "twitter:creator", content: "@muhammadfiaz_" }],

    // Favicons
    ["link", { rel: "icon", href: "/mcp.zig/favicon.ico" }],
    [
      "link",
      {
        rel: "icon",
        type: "image/png",
        sizes: "16x16",
        href: "/mcp.zig/favicon-16x16.png",
      },
    ],
    [
      "link",
      {
        rel: "icon",
        type: "image/png",
        sizes: "32x32",
        href: "/mcp.zig/favicon-32x32.png",
      },
    ],
    [
      "link",
      {
        rel: "apple-touch-icon",
        sizes: "180x180",
        href: "/mcp.zig/apple-touch-icon.png",
      },
    ],
    [
      "link",
      {
        rel: "icon",
        type: "image/png",
        sizes: "192x192",
        href: "/mcp.zig/android-chrome-192x192.png",
      },
    ],
    [
      "link",
      {
        rel: "icon",
        type: "image/png",
        sizes: "512x512",
        href: "/mcp.zig/android-chrome-512x512.png",
      },
    ],
    ["link", { rel: "manifest", href: "/mcp.zig/site.webmanifest" }],

    // Theme color
    ["meta", { name: "theme-color", content: "#f7a41d" }],
    ["meta", { name: "msapplication-TileColor", content: "#f7a41d" }],

    // Google Analytics (gtag.js)
    [
      "script",
      {
        async: "",
        src: `https://www.googletagmanager.com/gtag/js?id=${GA_ID}`,
      },
    ],
    [
      "script",
      {},
      `window.dataLayer = window.dataLayer || [];
function gtag(){dataLayer.push(arguments);}
gtag('js', new Date());
gtag('config', '${GA_ID}');`,
    ],

    // Google Tag Manager
    ...(GTM_ID
      ? ([
          [
            "script",
            {},
            `(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start': new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0], j=d.createElement(s), dl=l!='dataLayer'?'&l='+l:''; j.async=true; j.src='https://www.googletagmanager.com/gtm.js?id='+i+dl; f.parentNode.insertBefore(j,f);})(window,document,'script','dataLayer','${GTM_ID}');`,
          ],
          [
            "noscript",
            {},
            `<iframe src="https://www.googletagmanager.com/ns.html?id=${GTM_ID}" height="0" width="0" style="display:none;visibility:hidden"></iframe>`,
          ],
        ] as [string, Record<string, string>, string][])
      : []),

    // Google AdSense
    [
      "script",
      {
        async: "",
        src: `https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=${ADSENSE_CLIENT_ID}`,
        crossorigin: "anonymous",
      },
    ],
  ],

  ignoreDeadLinks: [/.*\.zig$/],

  transformPageData(pageData) {
    const pageTitle = pageData.title || SITE_NAME;
    const pageDescription = pageData.description || SITE_DESCRIPTION;
    const canonicalUrl = `${SITE_URL}/${pageData.relativePath.replace(/((^|\/)index)?\.md$/, "$2").replace(/\.md$/, "")}`;

    pageData.frontmatter.head ??= [];
    pageData.frontmatter.head.push(
      ["link", { rel: "canonical", href: canonicalUrl }],
      [
        "meta",
        { property: "og:title", content: `${pageTitle} | ${SITE_NAME}` },
      ],
      ["meta", { property: "og:url", content: canonicalUrl }],
    );

    if (pageData.frontmatter.description) {
      pageData.frontmatter.head.push(
        [
          "meta",
          {
            property: "og:description",
            content: pageData.frontmatter.description,
          },
        ],
        [
          "meta",
          { name: "description", content: pageData.frontmatter.description },
        ],
      );
    }

    // Dynamic JSON-LD Schema
    const isHome = pageData.relativePath === "index.md";
    const lastUpdated = pageData.lastUpdated
      ? new Date(pageData.lastUpdated).toISOString()
      : new Date().toISOString();

    const graph: Record<string, unknown>[] = [];

    // 1. WebSite Schema
    if (isHome) {
      graph.push({
        "@type": "WebSite",
        name: SITE_NAME,
        url: SITE_URL,
        description: SITE_DESCRIPTION,
        author: {
          "@type": "Person",
          name: "Muhammad Fiaz",
          url: "https://github.com/muhammad-fiaz",
        },
      });
    }

    // 2. Main Entity Schema
    const authorSchema = {
      "@type": "Person",
      name: "Muhammad Fiaz",
      url: "https://muhammadfiaz.com",
      sameAs: [
        "https://github.com/muhammad-fiaz",
        "https://www.linkedin.com/in/muhammad-fiaz-",
        "https://x.com/muhammadfiaz_",
      ],
    };

    const primarySchema: Record<string, unknown> = {
      "@type": isHome ? "SoftwareApplication" : "TechArticle",
      name: isHome ? SITE_NAME : pageTitle,
      description: pageDescription,
      url: canonicalUrl,
      image: `${SITE_URL}/cover.png`,
      author: authorSchema,
      publisher: {
        "@type": "Organization",
        name: "MCP.zig",
        url: SITE_URL,
        logo: {
          "@type": "ImageObject",
          url: `${SITE_URL}/logo.png`,
        },
      },
    };

    if (isHome) {
      Object.assign(primarySchema, {
        applicationCategory: "DeveloperApplication",
        operatingSystem: "Cross-platform",
        programmingLanguage: "Zig",
        offers: {
          "@type": "Offer",
          price: "0",
          priceCurrency: "USD",
        },
        downloadUrl: "https://github.com/muhammad-fiaz/mcp.zig",
        softwareVersion: "0.0.6",
        license: "https://opensource.org/licenses/MIT",
      });
    } else {
      const pathParts: string[] = String(pageData.relativePath).split("/");
      const section =
        pathParts.length > 1
          ? pathParts[0].charAt(0).toUpperCase() + pathParts[0].slice(1)
          : "Documentation";

      Object.assign(primarySchema, {
        headline: pageTitle,
        articleSection: section,
        mainEntityOfPage: {
          "@type": "WebPage",
          "@id": canonicalUrl,
        },
        datePublished: "2025-01-01T00:00:00Z",
        dateModified: lastUpdated,
      });
    }
    graph.push(primarySchema);

    // 3. BreadcrumbList Schema
    const breadcrumbs: Record<string, unknown>[] = [
      {
        "@type": "ListItem",
        position: 1,
        name: "Home",
        item: SITE_URL,
      },
    ];

    if (!isHome) {
      const pathParts: string[] = String(pageData.relativePath)
        .replace(/\.md$/, "")
        .split("/");
      let currentPath = SITE_URL;

      pathParts.forEach((part: string, index: number) => {
        currentPath += `/${part}`;
        const name = part
          .split("-")
          .map((s: string) => s.charAt(0).toUpperCase() + s.slice(1))
          .join(" ");

        breadcrumbs.push({
          "@type": "ListItem",
          position: index + 2,
          name: name,
          item: index === pathParts.length - 1 ? canonicalUrl : currentPath,
        });
      });
    }

    graph.push({
      "@type": "BreadcrumbList",
      itemListElement: breadcrumbs,
    });

    pageData.frontmatter.head.push([
      "script",
      { type: "application/ld+json" },
      JSON.stringify({
        "@context": "https://schema.org",
        "@graph": graph,
      }),
    ]);
  },

  theme: mcpTheme,

  themeConfig: {
    logo: "/logo.svg",
    siteTitle: "MCP.zig",

    nav: [
      { text: "Home", link: "/" },
      { text: "Guide", link: "/guide/getting-started" },
      { text: "API", link: "/api/" },
      { text: "Examples", link: "/examples/" },
      {
        text: "Official MCP",
        link: "https://modelcontextprotocol.io/docs/getting-started/intro",
        target: "_blank",
      },
      {
        text: "Support",
        items: [
          {
            text: "💖 Sponsor",
            link: "https://github.com/sponsors/muhammad-fiaz",
          },
          { text: "☕ Donate", link: "https://pay.muhammadfiaz.com" },
        ],
      },
      { text: "GitHub", link: "https://github.com/muhammad-fiaz/mcp.zig" },
    ],

    sidebar: [
      {
        text: "Introduction",
        items: [
          { text: "What is MCP?", link: "/guide/what-is-mcp" },
          { text: "Architecture", link: "/guide/architecture" },
          { text: "Protocol Version", link: "/guide/protocol-version" },
          { text: "Getting Started", link: "/guide/getting-started" },
          { text: "Installation", link: "/guide/installation" },
        ],
      },
      {
        text: "MCP Concepts",
        items: [
          { text: "Server Concepts", link: "/guide/server-concepts" },
          { text: "Client Concepts", link: "/guide/client-concepts" },
          { text: "Authorization", link: "/guide/authorization" },
          { text: "Inspector", link: "/guide/inspector" },
        ],
      },
      {
        text: "Zig API",
        items: [
          { text: "Server", link: "/guide/server" },
          { text: "Client", link: "/guide/client" },
          { text: "Tools", link: "/guide/tools" },
          { text: "Resources", link: "/guide/resources" },
          { text: "Prompts", link: "/guide/prompts" },
          { text: "Transport", link: "/guide/transport" },
        ],
      },
      {
        text: "Advanced",
        items: [
          { text: "JSON-RPC Protocol", link: "/guide/jsonrpc" },
          { text: "Schema Validation", link: "/guide/schema" },
          { text: "Error Handling", link: "/guide/error-handling" },
        ],
      },
      {
        text: "API Reference",
        items: [
          { text: "Overview", link: "/api/" },
          { text: "Server", link: "/api/server" },
          { text: "Client", link: "/api/client" },
          { text: "Protocol", link: "/api/protocol" },
          { text: "Types", link: "/api/types" },
        ],
      },
      {
        text: "Code Examples",
        items: [
          { text: "Overview", link: "/examples/" },
          { text: "Simple Server", link: "/examples/simple-server" },
          { text: "Simple Client", link: "/examples/simple-client" },
          { text: "Weather Server", link: "/examples/weather-server" },
          { text: "Calculator Server", link: "/examples/calculator-server" },
          { text: "Advanced Server", link: "/examples/advanced-server" },
          { text: "Filesystem Server", link: "/examples/filesystem-server" },
          { text: "Notes Server", link: "/examples/notes-server" },
          { text: "HTTP Server", link: "/examples/http-server" },
          { text: "Middleware Server", link: "/examples/middleware-server" },
          { text: "Batch Client", link: "/examples/batch-client" },
          { text: "Health Check", link: "/examples/health-check-example" },
          { text: "Shutdown", link: "/examples/shutdown-example" },
          { text: "Validator", link: "/examples/validator-example" },
          { text: "Rate Limiter", link: "/examples/rate-limiter-example" },
        ],
      },
      {
        text: "External Resources",
        items: [
          {
            text: "Official MCP Docs ↗",
            link: "https://modelcontextprotocol.io/docs/getting-started/intro",
          },
          {
            text: "MCP Specification ↗",
            link: "https://spec.modelcontextprotocol.io/",
          },
        ],
      },
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/muhammad-fiaz/mcp.zig" },
    ],

    footer: {
      message:
        'Released under the MIT License. <a href="https://modelcontextprotocol.io/docs/getting-started/intro" target="_blank">Official MCP Documentation ↗</a>',
      copyright: `Copyright © 2025-${new Date().getFullYear()} Muhammad Fiaz`,
    },

    search: {
      provider: "local",
    },

    editLink: {
      pattern: "https://github.com/muhammad-fiaz/mcp.zig/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },

    lastUpdated: {
      text: "Last updated",
      formatOptions: {
        dateStyle: "medium",
        timeStyle: "short",
      },
    },

    outline: {
      level: [2, 3],
    },
  },
});
