import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "mcp.zig",
  description: "Model Context Protocol for Zig - The first comprehensive MCP library for the Zig ecosystem",
  
  // Base path for GitHub Pages deployment
  base: '/mcp.zig/',
  
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/mcp.zig/logo.svg' }],
    ['meta', { name: 'theme-color', content: '#f7a41d' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:locale', content: 'en' }],
    ['meta', { property: 'og:title', content: 'mcp.zig | Model Context Protocol for Zig' }],
    ['meta', { property: 'og:description', content: 'The first comprehensive MCP library for Zig - bringing MCP support to the Zig ecosystem' }],
    ['meta', { property: 'og:site_name', content: 'mcp.zig' }],
    ['meta', { property: 'og:url', content: 'https://muhammad-fiaz.github.io/mcp.zig/' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: 'mcp.zig - Model Context Protocol for Zig' }],
    ['meta', { name: 'twitter:description', content: 'The first comprehensive MCP library for Zig' }],
  ],

  themeConfig: {
    // Logo
    logo: '/logo.svg',
    siteTitle: 'mcp.zig',
    
    // Navigation
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'API', link: '/api/' },
      { text: 'Examples', link: '/examples/' },
      { 
        text: 'Official MCP', 
        link: 'https://modelcontextprotocol.io/docs/getting-started/intro',
        target: '_blank'
      },
      {
        text: 'v0.0.4',
        items: [
          { text: 'Contributing', link: '/contributing' },
          { text: 'GitHub Releases', link: 'https://github.com/muhammad-fiaz/mcp.zig/releases' }
        ]
      }
    ],

    // Sidebar
    sidebar: {
      '/guide/': [
        {
          text: 'Introduction',
          items: [
            { text: 'What is MCP?', link: '/guide/what-is-mcp' },
            { text: 'Architecture', link: '/guide/architecture' },
            { text: 'Protocol Version', link: '/guide/protocol-version' },
            { text: 'Getting Started', link: '/guide/getting-started' },
            { text: 'Installation', link: '/guide/installation' }
          ]
        },
        {
          text: 'MCP Concepts',
          items: [
            { text: 'Server Concepts', link: '/guide/server-concepts' },
            { text: 'Client Concepts', link: '/guide/client-concepts' },
            { text: 'Authorization', link: '/guide/authorization' },
            { text: 'Inspector', link: '/guide/inspector' }
          ]
        },
        {
          text: 'Zig API',
          items: [
            { text: 'Server', link: '/guide/server' },
            { text: 'Client', link: '/guide/client' },
            { text: 'Tools', link: '/guide/tools' },
            { text: 'Resources', link: '/guide/resources' },
            { text: 'Prompts', link: '/guide/prompts' },
            { text: 'Transport', link: '/guide/transport' }
          ]
        },
        {
          text: 'Advanced',
          items: [
            { text: 'JSON-RPC Protocol', link: '/guide/jsonrpc' },
            { text: 'Schema Validation', link: '/guide/schema' },
            { text: 'Error Handling', link: '/guide/error-handling' }
          ]
        },
        {
          text: 'External Resources',
          items: [
            { text: 'Official MCP Docs ↗', link: 'https://modelcontextprotocol.io/docs/getting-started/intro' },
            { text: 'MCP Specification ↗', link: 'https://spec.modelcontextprotocol.io/' }
          ]
        }
      ],
      '/api/': [
        {
          text: 'API Reference',
          items: [
            { text: 'Overview', link: '/api/' },
            { text: 'Server', link: '/api/server' },
            { text: 'Client', link: '/api/client' },
            { text: 'Protocol', link: '/api/protocol' },
            { text: 'Types', link: '/api/types' }
          ]
        }
      ],
      '/examples/': [
        {
          text: 'Examples',
          items: [
            { text: 'Overview', link: '/examples/' },
            { text: 'Simple Server', link: '/examples/simple-server' },
            { text: 'Simple Client', link: '/examples/simple-client' },
            { text: 'Weather Server', link: '/examples/weather-server' },
            { text: 'Calculator Server', link: '/examples/calculator-server' }
          ]
        }
      ]
    },

    // Social links
    socialLinks: [
      { icon: 'github', link: 'https://github.com/muhammad-fiaz/mcp.zig' }
    ],

    // Footer
    footer: {
      message: 'Released under the MIT License. <a href="https://modelcontextprotocol.io/docs/getting-started/intro" target="_blank">Official MCP Documentation ↗</a>',
      copyright: 'Copyright © 2025-present <a href="https://github.com/muhammad-fiaz" target="_blank">Muhammad Fiaz</a>'
    },

    // Search
    search: {
      provider: 'local'
    },

    // Edit link
    editLink: {
      pattern: 'https://github.com/muhammad-fiaz/mcp.zig/edit/main/docs/:path',
      text: 'Edit this page on GitHub'
    },

    // Last updated
    lastUpdated: {
      text: 'Last updated',
      formatOptions: {
        dateStyle: 'medium',
        timeStyle: 'short'
      }
    },

    // Outline
    outline: {
      level: [2, 3]
    }
  }
})
