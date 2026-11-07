const {chromium}=require('playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
const browser=await chromium.launch({headless:true});
for(const width of [320,360,375,390,402,430,768,1024,1440]){
 const page=await browser.newPage({viewport:{width,height:900},isMobile:width<761,hasTouch:width<761});
 await page.route('**/*',route=>{let p=new URL(route.request().url()).pathname;if(p.startsWith('/api/'))return route.fulfill({json:{}});let file=path.join(__dirname,'../../Server/nosce/public',p==='/'?'index.html':p.replace('/site-assets/',''));if(!fs.existsSync(file))return route.abort();return route.fulfill({path:file});});
 await page.goto('http://nosce.test');await page.locator('[data-feed-mode=demo]').click();
 for(const size of ['small','medium','large']){
 await page.locator('button[data-size='+size+']').click();await page.waitForTimeout(550);
 const bounds=await page.evaluate(()=>{const card=document.querySelector('.market-widget'),stage=document.querySelector('.widget-stage');const c=card.getBoundingClientRect(),s=stage.getBoundingClientRect();return {left:c.left,right:c.right,top:c.top,bottom:c.bottom,sl:s.left,sr:s.right,st:s.top,sb:s.bottom,overflow:card.scrollWidth-card.clientWidth}});
 assert(bounds.left>=bounds.sl&&bounds.right<=bounds.sr&&bounds.top>=bounds.st&&bounds.bottom<=bounds.sb&&bounds.overflow<=1,JSON.stringify({width,size,bounds}));
 }
 for(const asset of ['BTC','ETH','SOL']){await page.locator('button[data-asset='+asset+']').click();await page.waitForFunction(()=>Array.from(document.querySelectorAll('[data-island-logo]')).every(x=>x.complete&&x.naturalWidth>0));for(const logo of await page.locator('[data-island-logo]').all()){assert((await logo.getAttribute('src')).endsWith('asset-'+asset.toLowerCase()+'.svg'));assert(await logo.evaluate(x=>x.complete&&x.naturalWidth>0));}}
 console.log(width+': all widget sizes fit; all Island logos switch');await page.close();
}
await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
