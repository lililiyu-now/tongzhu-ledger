import type { NextConfig } from 'next';
const config: NextConfig = { distDir: process.env.LOCAL_SANDBOX==='1'?'.next-local':'.next', poweredByHeader: false, serverExternalPackages: ['@electric-sql/pglite'], async headers() { return [{ source: '/(.*)', headers: [{ key: 'Referrer-Policy', value: 'no-referrer' }, {key:'X-Content-Type-Options',value:'nosniff'}, {key:'X-Frame-Options',value:'DENY'}] }]; } };
export default config;
