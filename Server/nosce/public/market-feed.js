/* Public, read-only Hyperliquid perpetual mark prices. No account or API keys. */
(function(root){
'use strict';
const SYMBOLS=['BTC','ETH','SOL'];
function parseContext(symbol,ctx,receivedAt,transport){
 if(!SYMBOLS.includes(symbol)||!ctx||typeof ctx!=='object')return null;
 const price=Number(ctx.markPx),previous=Number(ctx.prevDayPx);
 if(!Number.isFinite(price)||price<=0)return null;
 return {symbol,price,change:Number.isFinite(previous)&&previous>0?(price/previous-1)*100:null,receivedAt,transport};
}
class PublicMarketFeed{
 constructor(onQuote,onState,options={}){
  this.onQuote=onQuote;this.onState=onState;this.WebSocket=options.WebSocket||root.WebSocket;this.fetch=options.fetch||root.fetch.bind(root);this.now=options.now||Date.now;this.running=false;this.epoch=0;this.lastStream=0;this.lastPoll=0;this.latest={};this.retryDelay=5000;
 }
 start(){if(this.running)return;this.running=true;this.epoch++;this.onState('connecting');this.connect();this.poll();this.monitor=setInterval(()=>{if(!this.running)return;const now=this.now();if(this.socket&&now-(this.lastStream||this.connectedAt)>15000){this.disconnect();this.scheduleReconnect();}if(now-this.lastStream>10000&&now-this.lastPoll>=5000)this.poll();this.onState(Object.values(this.latest).some(q=>now-q.receivedAt<15000)?(now-this.lastStream<10000?'stream':'snapshot'):'stale');},2000);}
 stop(){this.running=false;this.epoch++;clearInterval(this.monitor);clearTimeout(this.retry);this.retry=null;this.pending?.abort();this.pending=null;this.disconnect();}
 disconnect(){const ws=this.socket;this.socket=null;if(ws){ws.onopen=ws.onmessage=ws.onclose=ws.onerror=null;ws.close();}clearInterval(this.ping);}
 scheduleReconnect(){if(!this.running||this.retry)return;this.retry=setTimeout(()=>{this.retry=null;this.connect();},this.retryDelay);this.retryDelay=Math.min(30000,this.retryDelay*2);}
 connect(){if(!this.running||this.socket)return;const epoch=this.epoch;this.connectedAt=this.now();this.lastStream=0;let ws;try{ws=new this.WebSocket('wss://api.hyperliquid.xyz/ws');}catch{this.scheduleReconnect();return;}this.socket=ws;
  ws.onopen=()=>{if(!this.running||epoch!==this.epoch||ws!==this.socket)return;for(const coin of SYMBOLS)ws.send(JSON.stringify({method:'subscribe',subscription:{type:'activeAssetCtx',coin}}));this.ping=setInterval(()=>{if(ws===this.socket&&ws.readyState===1)ws.send(JSON.stringify({method:'ping'}));},20000);};
  ws.onmessage=event=>{if(!this.running||epoch!==this.epoch||ws!==this.socket)return;try{const frame=JSON.parse(event.data);if(frame.channel!=='activeAssetCtx')return;const quote=parseContext(frame.data?.coin,frame.data?.ctx,this.now(),'stream');if(!quote)return;this.lastStream=quote.receivedAt;this.retryDelay=5000;this.latest[quote.symbol]=quote;this.onQuote(quote);this.onState('stream');}catch{/* Ignore malformed upstream frames, never fabricate a quote. */}};
  ws.onclose=()=>{if(ws!==this.socket)return;this.disconnect();this.scheduleReconnect();};ws.onerror=()=>{if(ws!==this.socket)return;this.disconnect();this.scheduleReconnect();};
 }
 async poll(){if(!this.running||this.pending)return;const epoch=this.epoch,started=this.now();this.lastPoll=started;const controller=new AbortController();this.pending=controller;const timeout=setTimeout(()=>controller.abort(),7000);
  try{const response=await this.fetch('https://api.hyperliquid.xyz/info',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type:'metaAndAssetCtxs'}),credentials:'omit',signal:controller.signal});if(!response.ok)throw Error('Quote source unavailable');const payload=await response.json();if(!this.running||epoch!==this.epoch||!Array.isArray(payload)||!Array.isArray(payload[0]?.universe)||!Array.isArray(payload[1]))return;
   const receivedAt=this.now();payload[0].universe.forEach((asset,index)=>{const quote=parseContext(asset.name,payload[1][index],receivedAt,'snapshot');if(!quote||(this.latest[quote.symbol]?.receivedAt??0)>=started)return;this.latest[quote.symbol]=quote;this.onQuote(quote);});
   this.onState(Object.values(this.latest).some(q=>this.now()-q.receivedAt<15000)?(this.now()-this.lastStream<10000?'stream':'snapshot'):'stale');
  }catch{if(this.running&&epoch===this.epoch)this.onState(Object.values(this.latest).some(q=>this.now()-q.receivedAt<15000)?'snapshot':'stale');}
  finally{clearTimeout(timeout);if(this.pending===controller)this.pending=null;}
 }
}
root.NoscePublicMarket={PublicMarketFeed,parseContext};
if(typeof module!=='undefined')module.exports=root.NoscePublicMarket;
})(globalThis);
