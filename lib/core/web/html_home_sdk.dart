import 'dart:convert';

/// Injected before the imported page's scripts. No SDK is installed in ordinary
/// remote web homes. fetch is only used for this session's loopback RPC.
String htmlHomeSdk(
  String endpoint,
  Map<String, dynamic> storage,
  Map<String, dynamic> viewport,
) {
  String json(Object? value) =>
      jsonEncode(value)
          .replaceAll('<', r'\u003c')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
  return '''(function(){
    'use strict';
    var endpoint=${json(endpoint)}, initial=${json(storage)}, viewport=${json(viewport)};
    async function rpc(method, args) {
      var response=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({method:method,args:args||{}})});
      var packet=await response.json();
      if(!response.ok||packet.error)throw new Error(packet.error||('HTTP '+response.status));
      return packet.result;
    }
    function publish(value){
      viewport=Object.assign({},viewport,value||{});
      var style=document.documentElement.style;
      ['Top','Bottom','Left','Right'].forEach(function(side){
        style.setProperty('--fm-safe-'+side.toLowerCase(),(viewport['safe'+side]||0)+'px');
      });
      style.setProperty('--fm-status-bar-height',(viewport.statusBarHeight||0)+'px');
      style.setProperty('--fm-chrome-mode',viewport.chromeMode||'normal');
      window.dispatchEvent(new CustomEvent('fmviewport',{detail:viewport}));
      return viewport;
    }
    window.__lumeHomeViewport=publish;
    function mediaOptions(base,item){
      base=base||{};item=item||{};
      var result={};
      ['format','password','credentials','referer','pic','wallPic'].forEach(function(key){
        if(base[key]!==undefined)result[key]=base[key];
        if(item[key]!==undefined)result[key]=item[key];
      });
      result.headers=Object.assign({},base.headers||{},item.headers||{});
      if(item.referer||base.referer)result.headers.Referer=item.referer||base.referer;
      return result;
    }
    function play(url,title,options){
      if(url&&typeof url==='object'){
        var item=url;
        url=item.mediaUrl||item.url;
        title=title||item.title||item.name||'';
        options=mediaOptions(item.options,mediaOptions(item,options));
      }
      if(typeof url!=='string'||!url.trim())return Promise.reject(new Error('没有可播放的媒体地址'));
      return rpc('play',{url:url,title:title||'',options:options||{}});
    }
    var playlists=Object.create(null), playlistSequence=0;
    async function resolveEpisode(detail,episode,resolver){
      var reference=Object.assign({},episode);
      Object.defineProperty(reference,'toString',{value:function(){return this.url||this.pageUrl||'';}});
      var resolved=episode.mediaUrl?{url:episode.mediaUrl}:
        resolver&&episode.resolve!==false?await resolver(reference):episode;
      if(typeof resolved==='string')resolved={url:resolved};
      if(!resolved||!(resolved.mediaUrl||resolved.url))throw new Error('剧集解析未返回媒体地址，请重试或更换线路');
      return {url:resolved.mediaUrl||resolved.url,
        title:detail.vod_name||detail.title||episode.name||episode.label||episode.title||'',
        options:mediaOptions(mediaOptions(detail,episode),resolved)};
    }
    window.__lumeResolveHomeEpisode=async function(job,playlist,index){
      try{
        var saved=playlists[playlist];
        if(!saved||!saved.episodes[index])throw new Error('网页选集已失效，请重新打开作品');
        var value=await resolveEpisode(saved.detail,saved.episodes[index],saved.resolver);
        await rpc('episode.result',{job:job,value:value});
      }catch(error){await rpc('episode.result',{job:job,error:String(error.message||error)});}
    };
    var storageWrites=Promise.resolve();
    function persist(method,args){
      storageWrites=storageWrites.then(function(){return rpc(method,args);}).catch(function(){});
    }
    try {
      var storage=window.localStorage, proto=Object.getPrototypeOf(storage);
      var set=proto.setItem, remove=proto.removeItem, clear=proto.clear;
      clear.call(storage);
      Object.keys(initial).forEach(function(key){set.call(storage,key,initial[key]);});
      proto.setItem=function(key,value){
        set.call(this,key,value);
        if(this===storage)persist('storage.set',{key:String(key),value:String(value)});
      };
      proto.removeItem=function(key){
        remove.call(this,key);
        if(this===storage)persist('storage.remove',{key:String(key)});
      };
      proto.clear=function(){
        clear.call(this);
        if(this===storage)persist('storage.clear',{});
      };
    } catch(e) {}
    window.fm={
      req:async function(url,options){
        try{return await rpc('request',{url:String(url),options:options||{}});}
        catch(e){return {ok:false,status:0,body:'',error:e.message,headers:{}};}
      },
      res:function(url,options){
        return endpoint.replace(/rpc\$/, 'resource')+'?url='+encodeURIComponent(url)+
          '&headers='+encodeURIComponent(JSON.stringify((options||{}).headers||{}));
      },
      play:play,
      vodInline:async function(detail){
        var episodes=(detail.episodes||[]).map(function(e){
          return typeof e==='string'?{url:e}:Object.assign({},e);
        });
        var episode=episodes.find(function(e){return e.active;})||
          episodes.find(function(e){return (e.name||e.label||e.title)===detail.mark;})||episodes[0];
        if(!episode)throw new Error('没有可播放的剧集');
        var index=episodes.indexOf(episode), id='playlist-'+(++playlistSequence);
        var resolver=window.__fmWebHomeInlineResolver;
        var value=await resolveEpisode(detail,episode,resolver);
        playlists[id]={detail:Object.assign({},detail),episodes:episodes,resolver:resolver};
        value.options.playlist={id:id,selected:index,
          itemId:String(detail.vod_id||detail.id||detail.vod_name||detail.title||''),
          cover:detail.pic||detail.vod_pic||detail.wallPic||'',
          description:detail.description||detail.vod_content||'',
          episodes:episodes.map(function(e,i){return {title:e.name||e.label||e.title||('第'+(i+1)+'集'),line:e.line||e.flag||''};})};
        return rpc('play',value);
      },
      cache:{
        get:function(key,scope){return rpc('cache.get',{key:String(key),scope:scope||''});},
        set:function(key,value,scope){return rpc('cache.set',{key:String(key),value:value,scope:scope||''});},
        remove:function(key,scope){return rpc('cache.remove',{key:String(key),scope:scope||''});}
      },
      config:function(){return Promise.resolve({driveCheck:false,webHome:true});},
      pan:{
        check:function(items){return Promise.resolve({results:items.map(function(){return {state:'uncertain'};})});},
        play:function(item){return rpc('play',{url:'push://'+item.url,title:item.title||'',options:{password:item.password||''}});}
      },
      ui:{
        getViewport:function(){return viewport;},
        setChrome:async function(options){return publish(await rpc('chrome',options||{}));},
        restoreChrome:async function(){return publish(await rpc('chrome',{mode:'normal'}));}
      }
    };
    publish(viewport);
    window.dispatchEvent(new Event('fmsdk'));
  })();''';
}
