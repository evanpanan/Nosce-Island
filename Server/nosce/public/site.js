'use strict';
const $=id=>document.getElementById(id);
const demoAssets={BTC:{price:'$78,382.00',change:'+1.03%'},ETH:{price:'$2,684.30',change:'+0.86%'},SOL:{price:'$93.18',change:'+2.17%'}};
const island=$('island');let pinned=false,hovered=false,focused=false,current='BTC';
function renderIsland(){const expanded=pinned||hovered||focused;island.classList.toggle('is-open',expanded);island.setAttribute('aria-expanded',String(expanded));island.querySelector('.island-expanded').setAttribute('aria-hidden',String(!expanded));island.querySelector('.island-compact').setAttribute('aria-hidden',String(expanded));island.setAttribute('aria-label',`${expanded?'收起':'展开'} ${current} 灵动岛演示；点击${pinned?'取消固定':'固定'}`);$('demo-instruction').textContent=pinned?'已固定展开 · 再次点击灵动岛收起':'悬停灵动岛展开 · 点击固定';}
island.addEventListener('pointerenter',event=>{if(event.pointerType==='mouse'){hovered=true;renderIsland();}});
island.addEventListener('pointerleave',()=>{hovered=false;renderIsland();});
island.addEventListener('focus',()=>{if(island.matches(':focus-visible')){focused=true;renderIsland();}});
island.addEventListener('blur',()=>{focused=false;renderIsland();});
island.addEventListener('click',()=>{pinned=!pinned;if(!pinned){hovered=false;focused=false;}renderIsland();});
island.addEventListener('keydown',event=>{if(event.key==='Escape'){pinned=false;focused=false;hovered=false;renderIsland();}});
document.querySelectorAll('[data-asset]').forEach(button=>button.addEventListener('click',()=>{current=button.dataset.asset;document.querySelectorAll('[data-asset]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));renderMarket();renderIsland();}));
const sizeNotes={small:'小号 · 只留一个重点，一眼读懂。',medium:'中号 · 并排关注，信息恰到好处。',large:'大号 · 展开自选，多一点全局视野。'};
document.querySelectorAll('[data-size][type=button]').forEach(button=>button.addEventListener('click',()=>{const size=button.dataset.size;document.querySelectorAll('[data-size][type=button]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));const widget=document.querySelector('.market-widget');widget.dataset.size=size;widget.setAttribute('aria-label',button.textContent+'号小组件示例');$('widget-caption').textContent=sizeNotes[size];}));
document.querySelectorAll('[data-colors]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('[data-colors]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));document.querySelector('.preferences-preview').classList.toggle('red-up',button.dataset.colors==='red-up');}));
// Rotation only starts on request, advances calmly, and ends after three changes.
let rotation=null,rotationSteps=0;
function stopRotation(){clearInterval(rotation);rotation=null;$('demo-play').textContent='播放轮播演示';$('demo-play').setAttribute('aria-pressed','false');}
$('demo-play').addEventListener('click',()=>{if(rotation){stopRotation();return;}rotationSteps=0;$('demo-play').textContent='暂停轮播';$('demo-play').setAttribute('aria-pressed','true');rotation=setInterval(()=>{const assets=Object.keys(demoAssets),next=assets[(assets.indexOf(current)+1)%assets.length];document.querySelector('[data-asset="'+next+'"]').click();if(++rotationSteps>=3)stopRotation();},5000);});
document.addEventListener('visibilitychange',()=>{if(document.hidden)stopRotation();});
if('IntersectionObserver' in window)new IntersectionObserver(entries=>{if(!entries[0].isIntersecting)stopRotation();}).observe($('experience'));
// Section entrances happen once; there are no decorative animation loops.
if('IntersectionObserver' in window&&!matchMedia('(prefers-reduced-motion: reduce)').matches){const observer=new IntersectionObserver(entries=>{for(const entry of entries){if(entry.isIntersecting){entry.target.classList.add('visible');observer.unobserve(entry.target);}}},{threshold:.08});document.querySelectorAll('.island-story,.widget-copy,.preferences-copy,.download-heading,.faq>div:first-child').forEach(item=>{item.classList.add('reveal');observer.observe(item);});}
function safeHTTPS(value){try{const url=new URL(value);return url.protocol==='https:'&&!url.username&&!url.password?url.href:null;}catch{return null;}}
function applyDownload(platform,url){const valid=safeHTTPS(url);if(!valid)return;const link=$(platform+'-download');link.href=valid;link.target='_blank';link.rel='noopener noreferrer';link.removeAttribute('aria-disabled');link.textContent=platform==='ios'?(new URL(valid).hostname==='testflight.apple.com'?'加入 iOS TestFlight 测试 ↗':'获取 iOS 版本 ↗'):'获取 Android 版本 ↗';$(platform+'-status').textContent='可获取';$(platform+'-description').textContent=platform==='ios'?'点击前往官方发布的 iOS 下载或测试页面，按页面提示安装。':'点击前往官方发布的安卓下载页面，查看该版本的功能与安装要求。';}
(async()=>{try{const response=await fetch('/api/public/downloads',{signal:AbortSignal.timeout(8000),credentials:'omit'});if(!response.ok)throw new Error('Unavailable');const data=await response.json();applyDownload('ios',data.ios);applyDownload('android',data.android);for(const key of ['privacy','terms']){const url=safeHTTPS(data[key]);if(url){const link=$(key+'-link');link.href=url;link.target='_blank';link.rel='noopener noreferrer';link.hidden=false;}}if(data.ios||data.android)$('download-note').textContent='请选择你的设备平台，下载状态以发布页面为准。演示行情的连接状态与来源以页面标注为准。';}catch{$('download-note').textContent='暂时无法读取最新下载状态，请稍后刷新。未确认的下载链接不会启用。';}})();
$('year').textContent=String(new Date().getFullYear());

// A single public connection feeds every surface on the website, not the iOS widgets.
let feedMode='live',feedState='connecting',marketRenderTimer=null,simulationTimer=null;
const liveQuotes={},simulatedQuotes={},histories={live:{BTC:[],ETH:[],SOL:[]},demo:{BTC:[],ETH:[],SOL:[]}};
const currency=new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',minimumFractionDigits:2,maximumFractionDigits:2});
const timeLabel=value=>new Date(value).toLocaleTimeString('zh-CN',{hour12:false});
const formatChange=value=>Number.isFinite(value)?(value>=0?'+':'')+value.toFixed(2)+'%':'—';
function chartPath(values,height){if(values.length<2)return '';const low=Math.min(...values),high=Math.max(...values),span=high-low;return values.map((value,index)=>`${index?'L':'M'}${(index*300/(values.length-1)).toFixed(2)} ${(span?height-4-(value-low)/span*(height-8):height/2).toFixed(2)}`).join(' ');}
function recordHistory(quote){const values=histories[feedMode][quote.symbol];values.push(quote.price);if(values.length>60)values.shift();}
function scheduleMarketRender(){if(!marketRenderTimer)marketRenderTimer=setTimeout(()=>{marketRenderTimer=null;renderMarket();},700);}
function renderMarket(){
 const quotes=feedMode==='live'?liveQuotes:simulatedQuotes,quote=quotes[current],now=Date.now(),modeHistory=histories[feedMode];
 document.querySelectorAll('[data-symbol]').forEach(item=>item.textContent=current);
 document.querySelectorAll('[data-price]').forEach(item=>{item.textContent=quote?currency.format(quote.price):'—';item.classList.toggle('down',!!quote&&quote.change<0);});
 $('island-change').textContent=quote?formatChange(quote.change):'—';$('island-change').classList.toggle('down',!!quote&&quote.change<0);
 document.querySelectorAll('[data-widget-price],[data-list-price],[data-widget-change],[data-list-change]').forEach(item=>{const symbol=item.dataset.widgetPrice||item.dataset.listPrice||item.dataset.widgetChange||item.dataset.listChange,q=quotes[symbol],isPrice=item.hasAttribute('data-widget-price')||item.hasAttribute('data-list-price');item.textContent=q?(isPrice?currency.format(q.price):formatChange(q.change)):'—';item.classList.toggle('down',!!q&&q.change<0);if(item.hasAttribute('data-list-price')){const parent=item.closest('.quote-value');parent.classList.toggle('negative',!!q&&q.change<0);parent.classList.toggle('positive',!q||q.change>=0);}});
 const islandGraph=$('island-chart').querySelector('path');islandGraph.setAttribute('d',chartPath(modeHistory[current],44));
 document.querySelectorAll('.widget-asset').forEach(item=>{const symbol=item.querySelector('[data-widget-price]').dataset.widgetPrice,path=item.querySelector('.sparkline path');if(path)path.setAttribute('d',chartPath(modeHistory[symbol],48));});
 if(feedMode==='demo'){$('feed-status').textContent='模拟数字 · 每 2.5 秒变化 · 非实时行情';$('island-source').textContent='模拟演示';$('widget-source').textContent='模拟数字';$('widget-received').textContent='模拟 · '+timeLabel(now);$('list-source').textContent='模拟数字 · 非实时行情';return;}
 const fresh=quote&&now-quote.receivedAt<15000;
 $('island-source').textContent=fresh?'HL · 标记价':quote?'连接中断':'连接中';
 const values=Object.values(quotes),allFresh=['BTC','ETH','SOL'].every(symbol=>quotes[symbol]&&now-quotes[symbol].receivedAt<15000);
 $('widget-source').textContent=allFresh?'Hyperliquid':values.length?'部分行情未更新':'连接中';
 $('widget-received').textContent=values.length?'收到 '+timeLabel(Math.min(...values.map(item=>item.receivedAt))):'等待行情';
 $('list-source').textContent=allFresh?'Hyperliquid · 合约标记价格':'公开行情 · 等待连接 / 更新';
 $('feed-status').textContent=fresh?`Hyperliquid · 合约标记价 · ${quote.transport==='stream'?'实时推送':'每 5 秒检查'} · 收到 ${timeLabel(quote.receivedAt)}`:quote?`连接暂不可用 · 保留 ${timeLabel(quote.receivedAt)} 的报价，可切换模拟演示`:(feedState==='connecting'?'正在连接 Hyperliquid 公开行情…':'暂未连接到行情源 · 可切换模拟演示');
}
const publicFeed=new NoscePublicMarket.PublicMarketFeed(quote=>{liveQuotes[quote.symbol]=quote;if(feedMode==='live'){recordHistory(quote);scheduleMarketRender();}},state=>{feedState=state;if(feedMode==='live')scheduleMarketRender();});
function simulateTick(){const now=Date.now(),bases={BTC:78382,ETH:2684.3,SOL:93.18};for(const [index,symbol]of Object.keys(bases).entries()){const base=bases[symbol],price=base*(1+.0012*Math.sin(now/9000+index*1.8));const quote={symbol,price,change:(price/(base/(1+(index===1?-.0086:.0103)))-1)*100,receivedAt:now};simulatedQuotes[symbol]=quote;recordHistory(quote);}renderMarket();}
function runChosenFeed(){if(document.hidden)return;if(feedMode==='live'){feedState='connecting';publicFeed.start();renderMarket();}else{simulateTick();simulationTimer=setInterval(simulateTick,2500);}}
function stopChosenFeed(){publicFeed.stop();clearInterval(simulationTimer);simulationTimer=null;}
document.querySelectorAll('[data-feed-mode]').forEach(button=>button.addEventListener('click',()=>{if(feedMode===button.dataset.feedMode)return;stopChosenFeed();feedMode=button.dataset.feedMode;document.querySelectorAll('[data-feed-mode]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));runChosenFeed();}));
document.addEventListener('visibilitychange',()=>{stopChosenFeed();if(!document.hidden)runChosenFeed();});
window.addEventListener('pagehide',stopChosenFeed);window.addEventListener('pageshow',event=>{if(event.persisted)runChosenFeed();});
renderMarket();runChosenFeed();
