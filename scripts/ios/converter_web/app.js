'use strict';
const fragment = new URLSearchParams(location.hash.slice(1));
const token = fragment.get('token') || '';
if (location.hash) history.replaceState(null, '', location.pathname);
const $ = id => document.getElementById(id);
let latest = null;
let uploading = false;
let stickyError = '';
function text(tag, value, className) { const el = document.createElement(tag); el.textContent = value; if(className) el.className = className; return el; }
function size(bytes) { return (bytes / 1048576).toFixed(1) + ' MiB'; }
async function request(path, options = {}) {
  const response = await fetch(path, {...options, headers: {...options.headers, Authorization: 'Bearer ' + token}, cache:'no-store'});
  const value = await response.json();
  if(!response.ok) throw new Error(value.error || 'Request failed');
  return value;
}
function render(state) {
  latest = state;
  $('connection').textContent = state.busy ? 'PC working' : 'PC ready';
  $('submit').disabled = uploading || state.busy;
  const list = $('jobs'); list.replaceChildren();
  if(!state.jobs.length) list.append(text('p','No conversions yet. Choose a video above.','detail'));
  for(const job of state.jobs) {
    const card = text('article','','job'); card.append(text('div',job.title,'job-title'));
    const p = job.progress || {};
    const stage = p.stage || job.state;
    let description = stage;
    if(p.total) description += ' · ' + (p.current || 0) + ' / ' + p.total + ' frames';
    if(p.output_bytes) description += ' · ' + size(p.output_bytes);
    if(job.error) description += ' · ' + job.error;
    card.append(text('div',description,'job-state' + (job.state === 'failed' ? ' error' : '')));
    if(job.sample_aspect_ratio_assumed === true) card.append(text('p','Source pixel aspect was unspecified: using square pixels and preserving stored width:height. / 來源未指定像素比例：以方形像素保留原始寬高比。','detail'));
    if(p.total && !['done','failed','cancelled'].includes(job.state)) {
      const bar = document.createElement('progress'); bar.max=p.total; bar.value=p.current||0; card.append(bar);
    }
    if(job.download_url) {
      const link = text('a','Download .tendies / 下載','download'); link.href=job.download_url; link.download=job.title+'.tendies'; card.append(link);
      card.append(text('p','Save to Files on iPad, then import the archive into AirCard. This button does not Flash it.','detail'));
    } else if(['queued','converting'].includes(job.state)) {
      const cancel=text('button','Cancel','cancel'); cancel.type='button'; cancel.onclick=async()=>{
        try { await request('/api/jobs/'+job.id+'/cancel',{method:'POST',body:''}); await poll(); } catch(error){ $('message').textContent=error.message; }
      }; card.append(cancel);
    }
    list.append(card);
  }
}
async function poll() {
  if(!token) { $('connection').textContent='Private link needed'; $('message').textContent='Use the full private URL printed by the PC converter. The #token portion is required. Reloading after it is removed requires reopening that link.'; $('submit').disabled=true; return; }
  try { render(await request('/api/state')); if(!uploading) $('message').textContent=stickyError || 'Connected to your PC. Full-length conversion stays local.'; }
  catch(error) { $('connection').textContent='Not connected'; $('message').textContent=error.message; $('submit').disabled=true; }
}
$('video').addEventListener('change',()=>{ const file=$('video').files[0]; if(file) $('title').value=file.name.replace(/\.[^.]+$/,'').slice(0,120); });
$('convert').addEventListener('submit',async event=>{
  event.preventDefault();
  const file=$('video').files[0]; if(!file || !token || uploading || latest?.busy) return;
  if(file.size<=0 || file.size>2*1024**3) { $('message').textContent='Choose a video between 1 byte and 2 GiB.'; return; }
  const query=new URLSearchParams({title:$('title').value,fps:$('fps').value,quality:$('quality').value,width:'1668',height:'2420'});
  if($('package-layout').value === 'posterBoard27') query.set('package_layout','posterBoard27');
  stickyError=''; uploading=true; $('submit').disabled=true; $('upload').hidden=false; $('upload').value=0;
  $('message').textContent='Uploading to your PC. Keep this page open until the upload finishes.';
  const xhr=new XMLHttpRequest(); xhr.open('POST','/api/jobs?'+query); xhr.setRequestHeader('Authorization','Bearer '+token); xhr.setRequestHeader('Content-Type','application/octet-stream');
  xhr.upload.onprogress=e=>{ if(e.lengthComputable) { $('upload').value=e.loaded/e.total*100; $('message').textContent='Uploading '+Math.round(e.loaded/e.total*100)+'% · '+size(e.loaded)+' / '+size(e.total); } };
  const finish=()=>{ uploading=false; $('upload').hidden=true; poll(); };
  xhr.onload=()=>{ if(xhr.status!==202) { try{stickyError=JSON.parse(xhr.responseText).error;}catch{stickyError='Upload failed';} } finish(); };
  xhr.onerror=()=>{ stickyError='Connection lost during upload. Reconnect and try again.'; finish(); };
  xhr.send(file);
});
(async function loop(){ await poll(); setTimeout(loop,1500); })();
