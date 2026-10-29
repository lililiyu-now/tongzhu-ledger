import type { Metadata } from 'next';
import './globals.css';
export const metadata:Metadata={title:'同住 · 合租账本',description:'每一笔分担，都清清楚楚。合租账单与室友协作。',robots:{index:false,follow:false}};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="zh-CN"><body>{children}</body></html>}
