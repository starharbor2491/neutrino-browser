// SPDX-License-Identifier: MPL-2.0
// DOM/platform adapter only. Rust owns rendering, validation and interaction state.
(()=>{'use strict';
const root=document.getElementById('app');let chain=Promise.resolve(),currentOverlay=false,generation=0,drag=null,resize=null,geometryFrame=0,returnFocus=null,composition=false,currentContext=null;
const native=()=>window.webkit?.messageHandlers?.neutrino;
async function transport(message){if(native())return await native().postMessage(message);const r=await fetch('/dispatch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(message)});if(!r.ok)throw Error('Connection unavailable');return await r.json();}
function selector(el){if(!el)return null;if(el.id)return '#'+CSS.escape(el.id);for(const key of ['data-setup','data-name','data-note','data-editor'])if(el.hasAttribute(key))return el.tagName.toLowerCase()+'['+key+'="'+CSS.escape(el.getAttribute(key))+'"]'+(el.hasAttribute('data-note-field')?'[data-note-field="'+CSS.escape(el.getAttribute('data-note-field'))+'"]':'');if(el.matches('button[data-op]'))return 'button'+(el.classList[0]&&el.classList[0]!=='selected'?'.'+CSS.escape(el.classList[0]):'')+['data-op','data-id','data-value','data-action','data-key','data-component','data-region'].filter(k=>el.hasAttribute(k)).map(k=>'['+k+'="'+CSS.escape(el.getAttribute(k))+'"]').join('');if(el.name)return el.tagName.toLowerCase()+'[name="'+CSS.escape(el.name)+'"]';return null;}
// Keep existing editable nodes alive: replacing a textarea destroys its IME session
// and native undo stack. Navigation identity, errors and geometry still update on
// every response; no entire-frame deferral is allowed while the user types.
function nodeKey(node) {
 if (node.nodeType !== Node.ELEMENT_NODE) return String(node.nodeType);
 const tag = node.tagName;
 if (node.id) return tag + '#' + node.id;
 for (const attr of ['data-note','data-tab','data-space','data-page']) {
  if (node.hasAttribute(attr)) return tag + ':' + attr + ':' + node.getAttribute(attr) + ':' + (node.getAttribute('data-note-field') || '');
 }
 if (node.matches('input,textarea,select')) return tag + ':' + (node.name || node.dataset.setup || node.dataset.name || node.dataset.editor || node.className);
 if (node.hasAttribute('data-op')) {
  const attrs = ['data-op','data-id','data-action','data-key','data-component','data-region'];
  if (!node.hasAttribute('data-key')) attrs.push('data-value');
  return tag + ':' + attrs.map(attr => node.getAttribute(attr) || '').join(':');
 }
 return tag + ':' + (node.classList[0] || '') + ':' + (node.dataset.folder || '');
}
function reconcile(parent, incoming, preserveEditing) {
 const available = new Map();
 for (const node of parent.childNodes) {
  const key = nodeKey(node);
  if (!available.has(key)) available.set(key, []);
  available.get(key).push(node);
 }
 let cursor = parent.firstChild;
 for (const fresh of [...incoming.childNodes]) {
  const current = available.get(nodeKey(fresh))?.shift();
  if (!current) { parent.insertBefore(fresh.cloneNode(true), cursor); continue; }
  if (current !== cursor) parent.insertBefore(current, cursor);
  if (current.nodeType === Node.ELEMENT_NODE) {
   const editing = preserveEditing && current.matches('input,textarea,select') &&
    (current === document.activeElement || current.closest('form[data-form]'));
   for (const attr of [...current.attributes]) {
    if (!fresh.hasAttribute(attr.name) && !(editing && attr.name === 'value')) current.removeAttribute(attr.name);
   }
   for (const attr of fresh.attributes) {
    if (!(editing && attr.name === 'value') && current.getAttribute(attr.name) !== attr.value) current.setAttribute(attr.name, attr.value);
   }
   if (editing && current.matches('select')) {
    const selected = current.value;
    reconcile(current, fresh, preserveEditing);
    const usable = [...current.options].find(option => option.value === selected && !option.disabled);
    const fallback = [...current.options].find(option => option.value === fresh.value && !option.disabled) || [...current.options].find(option => !option.disabled);
    current.value = (usable || fallback)?.value || '';
   } else if (!editing) {
    reconcile(current, fresh, preserveEditing);
    if (current.matches('input,textarea,select') && current.value !== fresh.value) current.value = fresh.value;
   }
  } else if (current.nodeValue !== fresh.nodeValue) current.nodeValue = fresh.nodeValue;
  cursor = current.nextSibling;
 }
 for (const nodes of available.values()) for (const node of nodes) node.remove();
}
function patch(result) {
 if (result.generation && result.generation < generation) return;
 if (result.generation) generation = result.generation;
 if (result.error) { announce(result.error); return; }
 if (!result.html) return;
 const sameContext = currentContext === null || currentContext === result.context;
 if (result.context) currentContext = result.context;
 const active = document.activeElement, key = selector(active);
 const selection = active && typeof active.selectionStart === 'number' ? [active.selectionStart, active.selectionEnd] : null;
 const preserved = sameContext && key && active.matches('input,textarea') ? active.value : null;
 const scrolls = [...root.querySelectorAll('.tabs-scroll,.setup-content,.setup-form,.settings-content,.editor-inspector,.library-content,.note-list')].map(e => [e.className,e.scrollTop]);
 const openDetails = [...root.querySelectorAll('details[open]')].map(e => e.className);
 const hadDialog = !!topDialog();
 const template = document.createElement('template');
 template.innerHTML = result.html;
 reconcile(root, template.content, sameContext);
 currentOverlay = !!result.overlay;
 const dialog = topDialog();
 for (const el of root.querySelectorAll('.browser-shell,.editor,.utility-screen,.command-palette')) el.inert = !!dialog && !el.contains(dialog) && el !== dialog;
 if (dialog && !hadDialog) returnFocus = key;
 for (const cls of openDetails) { const el = root.getElementsByClassName(cls)[0]; if (el) el.open = true; }
 for (const [cls,top] of scrolls) { const el = root.getElementsByClassName(cls)[0]; if (el) el.scrollTop = top; }
 const next = key ? root.querySelector(key) : null;
 if (result.focus && (!next || next.id !== result.focus)) {
  const focus = document.getElementById(result.focus); focus?.focus({preventScroll:true}); focus?.select?.();
 } else if (next && (!dialog || dialog.contains(next))) {
  if (preserved !== null && next.value !== preserved) next.value = preserved;
  if (document.activeElement !== next) next.focus({preventScroll:true});
  if (!composition && next !== active && selection && next.setSelectionRange && next.type !== 'number' && next.type !== 'range') try { next.setSelectionRange(...selection); } catch {}
 } else if (result.focus) {
  const el = document.getElementById(result.focus); if (el) { el.focus({preventScroll:true}); if (el.id === 'command-input') el.select(); }
 } else if (dialog) dialog.querySelector('input,button:not(:disabled),select')?.focus({preventScroll:true});
 else if (hadDialog && returnFocus) { root.querySelector(returnFocus)?.focus({preventScroll:true}); returnFocus = null; }
 announce(result.announce); scalePreview(); scheduleGeometry();
}
function topDialog(){return root.querySelector('.popover-menu')||root.querySelector('.command-palette')||root.querySelector('.utility-screen');}
function announce(value){if(value)document.getElementById('announcer').textContent=value;}
function send(request){chain=chain.then(()=>transport({kind:'action',request})).then(patch).catch(e=>announce('Could not complete that action. '+e.message));return chain;}
window.neutrino={receive:patch,command:send};
function scalePreview(){const frame=root.querySelector('.editor-preview'),canvas=root.querySelector('.preview-canvas');if(!frame||!canvas)return;const width=window.innerWidth,height=window.innerHeight;const scale=Math.min(frame.clientWidth/width,frame.clientHeight/height);canvas.style.width=width+'px';canvas.style.height=height+'px';canvas.style.transform='scale('+scale+')';canvas.style.left=(frame.clientWidth-width*scale)/2+'px';canvas.style.top=(frame.clientHeight-height*scale)/2+'px';}
function scheduleGeometry(){scalePreview();cancelAnimationFrame(geometryFrame);geometryFrame=requestAnimationFrame(()=>{if(!native())return;const pages=[...root.querySelectorAll('.browser-shell:not(.editing-preview) .native-page')].map(el=>{const r=el.getBoundingClientRect();return{id:el.dataset.page,x:r.x,y:r.y,width:r.width,height:r.height};});native().postMessage({kind:'geometry',generation,overlay:currentOverlay,pages,dragRegions:[...root.querySelectorAll('[data-window-drag]')].filter(e=>!e.closest('.editing-preview')).map(e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};})}).catch(()=>{});});}
new ResizeObserver(scheduleGeometry).observe(root);window.addEventListener('resize',scheduleGeometry);
function dataRequest(el){const r={op:el.dataset.op};for(const[key,value]of Object.entries(el.dataset)){if(key==='op'||key==='type')continue;r[key==='folderId'?'folderID':key==='spaceId'?'spaceID':key]=value;}if(r.op==='editor-scope'||el.dataset.type==='bool')r.value=r.value==='true';if(r.index!==undefined)r.index=Number(r.index);return r;}
document.addEventListener('click',e=>{if(e.target.closest('.editing-preview'))return;const button=e.target.closest('[data-op]');if(button&&!button.disabled){e.preventDefault();send(dataRequest(button));return;}if(e.target.matches('[data-dismiss]'))send({op:'escape'});});
document.addEventListener('dblclick',e=>{if(e.target.closest('[data-window-drag]'))native()?.postMessage({kind:'zoom'});});
document.addEventListener('compositionstart',()=>{composition=true;});
document.addEventListener('compositionend',()=>{composition=false;});
document.addEventListener('input',e=>{const el=e.target;if(el.dataset.note)transport({kind:'action',request:{op:'native',action:'saveNote',id:el.dataset.note,value:{field:el.dataset.noteField,text:el.value}}}).then(result=>patch({...result,passive:true})).catch(e=>announce('Could not save note. '+e.message));else if(el.id==='command-input')send({op:'query',value:el.value});else if(el.dataset.setup)send({op:'setup-field',key:el.dataset.setup,value:el.value});else if(el.dataset.name!==undefined)send({op:'name',value:el.value});});
document.addEventListener('change',e=>{const el=e.target;if(el.dataset.scope)send({op:'editor-scope',value:el.value==='true'});if(el.dataset.editor)send({op:'editor-value',key:el.dataset.editor,value:Number(el.value)});if(el.name==='provider'){const input=el.form.elements.endpoint;input.value=el.value==='local'?'http://localhost:1234/v1':el.value==='xAI'?'https://api.x.ai/v1':'https://api.openai.com/v1';el.form.elements.key.value='';}});
document.addEventListener('submit',e=>{e.preventDefault();const form=e.target;if(form.dataset.form==='credential'){const f=new FormData(form);const request={op:'saveCredential',origin:f.get('origin'),username:f.get('username'),password:f.get('password')};form.elements.password.value='';send(request);}else if(form.dataset.form==='find'){send({op:'find',value:new FormData(form).get('find')});send({op:'escape'});}else if(form.dataset.form==='ai'){const f=new FormData(form);const request={op:'saveAI',provider:f.get('provider'),endpoint:f.get('endpoint'),model:f.get('model'),key:f.get('key'),useAccount:f.get('useAccount')==='account'};form.elements.key.value='';send(request);}else if(form.dataset.form==='assistant')send({op:'assistant',value:new FormData(form).get('prompt')});});
document.addEventListener('keydown',e=>{const typing=e.target.matches('textarea,select,input:not([type=range]):not([type=checkbox]):not([type=radio])'),command=e.metaKey||e.ctrlKey;
 if(e.key==='Escape'){e.preventDefault();if(resize){finishResize(false);return;}send({op:'escape'});return;}
 if(e.key==='Tab'){const modal=topDialog();if(modal){const list=[...modal.querySelectorAll('button:not(:disabled),input,textarea,select,[tabindex="0"]')].filter(x=>x.getClientRects().length);if(list.length){const first=list[0],last=list[list.length-1];if(e.shiftKey&&(document.activeElement===first||!modal.contains(document.activeElement))){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}}return;}
 if(e.target.id==='command-input'){if(['ArrowDown','ArrowUp','Enter'].includes(e.key)){e.preventDefault();send({op:e.key==='Enter'?'activate-result':e.key==='ArrowDown'?'result-next':'result-previous'});}return;}
 if(e.target.matches('[data-resize]')&&['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();const v=Number(e.target.getAttribute('aria-valuenow'))+(e.key==='ArrowRight'?8:-8);send({op:'sidebar-width',value:Math.max(200,Math.min(340,v))});return;}
 if(command&&e.key.toLowerCase()==='l'){e.preventDefault();send({op:'palette'});}else if(command&&e.key.toLowerCase()==='t'){e.preventDefault();send({op:e.shiftKey?'reopenTab':'newTab'});}else if(command&&e.key.toLowerCase()==='z'&&!typing){e.preventDefault();send({op:root.querySelector('.editor')?(e.shiftKey?'editor-redo':'editor-undo'):(e.shiftKey?'noop':'undo-tabs')});}else if(command&&e.key===','){e.preventDefault();send({op:'screen',value:'settings'});}else if(command&&e.key.toLowerCase()==='d'){e.preventDefault();send({op:'bookmark'});}else if(command&&e.key.toLowerCase()==='b'){e.preventDefault();send({op:'sidebar'});}else if(e.altKey&&e.shiftKey&&['ArrowUp','ArrowDown'].includes(e.key)){const tab=e.target.closest('[data-tab]');if(tab){const tabs=[...tab.parentElement.querySelectorAll(':scope > [data-tab]')];const at=tabs.indexOf(tab),target=tabs[at+(e.key==='ArrowUp'?-1:2)];e.preventDefault();if(e.key==='ArrowUp'&&at===0)return;send({op:'move-tab',id:tab.dataset.tab,before:target?.dataset.tab||'',group:tab.dataset.group,folderID:tab.dataset.folder});}}
});
document.addEventListener('contextmenu',e=>{const tab=e.target.closest('[data-tab]');if(tab){e.preventDefault();send({op:'menu',value:'tab:'+tab.dataset.tab});}});
function clearTargets(){root.querySelectorAll('.drop-hover,.drop-before').forEach(x=>x.classList.remove('drop-hover','drop-before'));}
document.addEventListener('dragstart',e=>{const tab=e.target.closest('[data-tab]'),component=e.target.closest('[data-component]');if(tab){drag={kind:'tab',id:tab.dataset.tab};document.body.classList.add('dragging-tab');tab.classList.add('drag-source');}else if(component){drag={kind:'component',component:component.dataset.component};document.body.classList.add('dragging-component');root.querySelectorAll('[data-dock]').forEach(el=>{const r=el.dataset.dock;el.classList.toggle('valid',drag.component==='tabs'||drag.component==='navigation'&&['top','bottom'].includes(r)||drag.component==='panels'&&['leading','trailing'].includes(r));});}else return;e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('application/x-neutrino',JSON.stringify(drag));});
document.addEventListener('dragover',e=>{if(!drag)return;clearTargets();let target=drag.kind==='component'?e.target.closest('[data-dock].valid'):e.target.closest('[data-tab],[data-space],[data-drop-group]');if(!target)return;if(drag.kind==='tab'&&target.dataset.tab===drag.id)return;e.preventDefault();e.dataTransfer.dropEffect='move';target.classList.add(target.dataset.tab?'drop-before':'drop-hover');const scroller=e.target.closest('.tabs-scroll');if(scroller){const r=scroller.getBoundingClientRect();if(e.clientY<r.top+30)scroller.scrollTop-=9;else if(e.clientY>r.bottom-30)scroller.scrollTop+=9;}});
document.addEventListener('drop',e=>{if(!drag)return;const target=drag.kind==='component'?e.target.closest('[data-dock].valid'):e.target.closest('[data-tab],[data-space],[data-drop-group]');if(!target)return;e.preventDefault();if(drag.kind==='component')send({op:'dock',component:drag.component,region:target.dataset.dock});else if(target.dataset.space)send({op:'move-space',id:drag.id,spaceID:target.dataset.space});else send({op:'move-tab',id:drag.id,before:target.dataset.tab||'',group:target.dataset.group||target.dataset.dropGroup,folderID:target.dataset.folder||''});cleanupDrag();});
function cleanupDrag(){drag=null;document.body.classList.remove('dragging-tab','dragging-component');root.querySelectorAll('.drag-source,.valid').forEach(x=>x.classList.remove('drag-source','valid'));clearTargets();}
document.addEventListener('dragend',cleanupDrag);
document.addEventListener('pointerdown',e=>{const handle=e.target.closest('[data-resize]');if(handle){const shell=handle.closest('.browser-shell'),start=Number(handle.getAttribute('aria-valuenow'));resize={handle,shell,start,x:e.clientX,value:start,trailing:shell.classList.contains('placement-trailing')};handle.setPointerCapture(e.pointerId);e.preventDefault();}});
document.addEventListener('pointermove',e=>{if(!resize)return;resize.value=Math.max(200,Math.min(340,resize.start+(e.clientX-resize.x)*(resize.trailing?-1:1)));resize.shell.style.setProperty('--rail-width',resize.value+'px');resize.handle.setAttribute('aria-valuenow',Math.round(resize.value));scheduleGeometry();});
function finishResize(commit){if(!resize)return;const r=resize;resize=null;if(commit)send({op:'sidebar-width',value:r.value});else{r.shell.style.setProperty('--rail-width',r.start+'px');r.handle.setAttribute('aria-valuenow',r.start);scheduleGeometry();}}
document.addEventListener('pointerup',()=>finishResize(true));document.addEventListener('pointercancel',()=>finishResize(false));
transport({kind:'ready'}).then(patch).catch(e=>announce(e.message));
})();
