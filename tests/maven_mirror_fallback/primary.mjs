import http from 'node:http';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
const mode = process.env.MODE ?? 'both-429';
const log = process.env.LOG ?? 'requests.jsonl';
const pom = '<?xml version="1.0"?><project><modelVersion>4.0.0</modelVersion><groupId>junit</groupId><artifactId>junit</artifactId><version>4.13.2</version><packaging>jar</packaging></project>';
const server = http.createServer(async (req,res) => {
 const t = new Date().toISOString();
 let status = 429, body = 'controlled primary 429';
 if (mode === 'pom-200-jar-429' && /junit-4\.13\.2\.pom(?:\.(?:sha1|md5))?$/.test(req.url)) {
   status = 200;
   const suffix = req.url.match(/\.pom\.(sha1|md5)$/)?.[1];
   body = suffix ? crypto.createHash(suffix).update(pom).digest('hex') : pom;
 }
 res.statusCode = status;
 res.setHeader('content-type', status === 200 ? 'application/xml' : 'text/plain');
 res.end(body);
 await fs.appendFile(log,JSON.stringify({time:t,method:req.method,path:req.url,status})+'\n');
});
server.listen(18765,'127.0.0.1',()=>console.log(JSON.stringify({ready:true,mode,port:18765})));
