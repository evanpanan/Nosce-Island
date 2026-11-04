const {test}=require('node:test');const assert=require('node:assert/strict');
const {PublicMarketFeed,parseContext}=require('../../Server/nosce/public/market-feed.js');
test('public quote decoder accepts only valid, supported mark prices',()=>{
 assert.equal(parseContext('BTC',{markPx:'80195',prevDayPx:'80000'},123,'stream').price,80195);
 assert.equal(parseContext('BTC',{markPx:'80195',prevDayPx:'80000'},123,'stream').receivedAt,123);
 for(const price of ['NaN','Infinity','',0,-1,{},null])assert.equal(parseContext('BTC',{markPx:price},123,'stream'),null);
 assert.equal(parseContext('not-supported',{markPx:'4'},123,'stream'),null);
 assert.equal(parseContext('SOL',{markPx:'93',prevDayPx:'0'},123,'stream').change,null);
});
test('late HTTP response cannot replace newer streaming data; stop fences callbacks',async()=>{
 let complete;const quotes=[];let clock=100;class WS{constructor(){WS.last=this;}send(){}close(){}}
 const feed=new PublicMarketFeed(q=>quotes.push(q),()=>{},{WebSocket:WS,now:()=>clock,fetch:()=>new Promise(resolve=>complete=resolve)});
 feed.start();const ws=WS.last;ws.onopen();clock=200;
 ws.onmessage({data:JSON.stringify({channel:'activeAssetCtx',data:{coin:'BTC',ctx:{markPx:'90000',prevDayPx:'80000'}}})});
 complete({ok:true,json:async()=>[{universe:[{name:'BTC'}]},[{markPx:'70000',prevDayPx:'80000'}]]});
 await new Promise(resolve=>setImmediate(resolve));assert.equal(quotes.length,1);assert.equal(quotes[0].price,90000);
 const oldCallback=ws.onmessage;feed.stop();clock=300;oldCallback({data:JSON.stringify({channel:'activeAssetCtx',data:{coin:'BTC',ctx:{markPx:'60000'}}})});assert.equal(quotes.length,1);
});
test('public HTTP fallback decodes the same real mark price and change',async()=>{
 const quotes=[];class WS{send(){}close(){}}
 const feed=new PublicMarketFeed(q=>quotes.push(q),()=>{},{WebSocket:WS,now:()=>500,fetch:async()=>({ok:true,json:async()=>[{universe:[{name:'BTC'},{name:'ETH'},{name:'UNSUPPORTED'}]},[{markPx:'88000',prevDayPx:'80000'},{markPx:'2000',prevDayPx:'2500'},{markPx:'123'}]]})});
 feed.start();await new Promise(resolve=>setImmediate(resolve));feed.stop();assert.deepEqual(quotes.map(q=>q.symbol),['BTC','ETH']);assert(Math.abs(quotes[0].change-10)<1e-8);assert(Math.abs(quotes[1].change+20)<1e-8);assert.equal(quotes[0].transport,'snapshot');
});
