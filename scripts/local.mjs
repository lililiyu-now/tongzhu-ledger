import {spawn} from 'node:child_process';
const child=spawn(process.execPath,['node_modules/next/dist/bin/next','dev','--webpack','--hostname','127.0.0.1','--port','3000'],{stdio:'inherit',env:{...process.env,WATCHPACK_POLLING:'true',LOCAL_SANDBOX:'1',NEXT_PUBLIC_LOCAL_SANDBOX:'1'}});
child.on('exit',code=>process.exit(code??1));for(const sig of ['SIGINT','SIGTERM'])process.on(sig,()=>child.kill(sig));
