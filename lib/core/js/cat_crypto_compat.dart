/// Node crypto wrappers preserve synchronous call sites; primitives run in Dart.
const catCryptoCompatibility = r'''
  function hostCrypto(value) { return LumeBridge.invokeSync('crypto', value); }
  function binary(value, encoding) { return Buffer.from(Array.isArray(value)?value:toBytes(value, encoding)).toString('base64'); }
  function output(value, encoding) { var b=Buffer.from(value,'base64'); return encoding ? b.toString(encoding) : b; }
  function hostHash(algorithm,key) {
    if(!/^(md5|sha-?(1|224|256|384|512))$/i.test(algorithm))throw new Error('Unsupported digest algorithm: '+algorithm);
    var chunks=[],length=0,done=false;
    return {update:function(data,encoding){if(done)throw new Error('Digest already called');var b=toBytes(data,encoding);length+=b.length;if(length>4*1024*1024)throw new RangeError('Crypto input too large');chunks.push(b);return this;},
      digest:function(encoding){if(done)throw new Error('Digest already called');done=true;var bytes=[];chunks.forEach(function(b){bytes=bytes.concat(b);});return output(hostCrypto({operation:key===undefined?'digest':'hmac',algorithm:algorithm,key:key===undefined?'':binary(key),data:binary(bytes)}),encoding);}};
  }
  function createCipher(algorithm,key,iv,encrypt,options) {
    var chunks=[],length=0,done=false,padding=true,aad='',tag='',tagLength=options&&options.authTagLength||16;
    if(!/^aes-(128|192|256)-(cbc|ecb|ctr|gcm|cfb|ofb)$/i.test(algorithm))throw new Error('Unsupported cipher: '+algorithm);
    var keyBytes=toBytes(key),ivBytes=iv==null?[]:toBytes(iv),parts=algorithm.toLowerCase().split('-');
    if(keyBytes.length*8!==Number(parts[1])||(parts[2]==='ecb'?ivBytes.length!==0:parts[2]==='gcm'?(ivBytes.length===0||ivBytes.length>60):ivBytes.length!==16))throw new Error('Invalid cipher key or IV length');
    var key64=binary(keyBytes),iv64=binary(ivBytes),gcm=/-gcm$/i.test(algorithm);
    function active(){if(done)throw new Error('Cipher already finalized');}
    return {
      update:function(data,inputEncoding,outputEncoding){active();var b=toBytes(data,inputEncoding);length+=b.length;if(length>4*1024*1024)throw new RangeError('Crypto input too large');chunks.push(b);return outputEncoding?'':Buffer.alloc(0);},
      setAutoPadding:function(value){active();padding=value!==false;return this;},
      setAAD:function(value){active();if(!gcm||length)throw new Error('Invalid AAD state');aad=binary(value);return this;},
      setAuthTag:function(value){active();if(encrypt||!gcm)throw new Error('Invalid tag state');tag=binary(value);return this;},
      getAuthTag:function(){if(!encrypt||!gcm||!done||!tag)throw new Error('Auth tag unavailable');return output(tag);},
      final:function(encoding){active();done=true;var bytes=[];chunks.forEach(function(b){bytes=bytes.concat(b);});var r=hostCrypto({operation:'aes',algorithm:algorithm,key:key64,iv:iv64,data:binary(bytes),encrypt:encrypt,padding:padding,aad:aad,tag:tag,tagLength:tagLength});if(r.tag)tag=r.tag;return output(r.data,encoding);}
    };
  }
  cryptoModule.createHash=function(a){return hostHash(a);};
  cryptoModule.createHmac=function(a,k){return hostHash(a,k);};
  cryptoModule.getHashes=function(){return ['md5','sha1','sha224','sha256','sha384','sha512'];};
  cryptoModule.getCiphers=function(){var r=[];[128,192,256].forEach(function(n){['cbc','ecb','ctr','gcm','cfb','ofb'].forEach(function(m){r.push('aes-'+n+'-'+m);});});return r;};
  cryptoModule.createCipheriv=function(a,k,i,o){return createCipher(a,k,i,true,o);};
  cryptoModule.createDecipheriv=function(a,k,i,o){return createCipher(a,k,i,false,o);};
  cryptoModule.pbkdf2Sync=function(password,salt,count,length,algorithm){return output(hostCrypto({operation:'pbkdf2',algorithm:algorithm,key:binary(password),salt:binary(salt),iterations:count,length:length}));};
  cryptoModule.pbkdf2=function(p,s,c,l,a,cb){if(typeof cb!=='function')throw new TypeError('Callback required');Promise.resolve().then(function(){return cryptoModule.pbkdf2Sync(p,s,c,l,a);}).then(function(v){cb(null,v);},cb);};
  cryptoModule.hkdfSync=function(a,key,salt,info,length){return output(hostCrypto({operation:'hkdf',algorithm:a,key:binary(key),salt:binary(salt),info:binary(info),length:length}))._b.buffer;};
  cryptoModule.hkdf=function(a,k,s,i,l,cb){if(typeof cb!=='function')throw new TypeError('Callback required');Promise.resolve().then(function(){return cryptoModule.hkdfSync(a,k,s,i,l);}).then(function(v){cb(null,v);},cb);};
  cryptoModule.scryptSync=function(key,salt,length,options){options=options||{};return output(hostCrypto({operation:'scrypt',key:binary(key),salt:binary(salt),length:length,N:options.N||options.cost,r:options.r||options.blockSize,p:options.p||options.parallelization}));};
  cryptoModule.scrypt=function(k,s,l,o,cb){if(typeof o==='function'){cb=o;o={};}if(typeof cb!=='function')throw new TypeError('Callback required');Promise.resolve().then(function(){return cryptoModule.scryptSync(k,s,l,o);}).then(function(v){cb(null,v);},cb);};
  cryptoModule.constants={RSA_PKCS1_PADDING:1,RSA_NO_PADDING:3,RSA_PKCS1_OAEP_PADDING:4};
  function keyOptions(key){var o=typeof key==='string'||Buffer.isBuffer(key)?{key:key}:key;if(!o||!o.key)throw new TypeError('PEM key required');return {pem:typeof o.key==='string'?o.key:Buffer.from(o.key).toString(),padding:o.padding,oaepHash:o.oaepHash,label:o.oaepLabel?binary(o.oaepLabel):''};}
  ['publicEncrypt','privateDecrypt','privateEncrypt','publicDecrypt'].forEach(function(name){cryptoModule[name]=function(key,data){var o=keyOptions(key),priv=name.indexOf('private')===0,enc=/Encrypt$/.test(name);if(o.padding===undefined)o.padding=(name==='privateEncrypt'||name==='publicDecrypt')?1:4;return output(hostCrypto(Object.assign(o,{operation:'rsa',private:priv,encrypt:enc,data:binary(data)})));};});
  function signer(algorithm,verify){var chunks=[],length=0,done=false;var value={update:function(data,encoding){if(done)throw new Error('Sign already finalized');var b=toBytes(data,encoding);length+=b.length;if(length>4*1024*1024)throw new RangeError('Crypto input too large');chunks.push(b);return value;}};
    value[verify?'verify':'sign']=function(key,signature,encoding){if(done)throw new Error('Sign already finalized');done=true;var data=[];chunks.forEach(function(b){data=data.concat(b);});var o=keyOptions(key);if(o.padding===undefined)o.padding=1;var result=hostCrypto(Object.assign(o,{operation:verify?'verify':'sign',algorithm:algorithm,data:binary(data),signature:verify?binary(signature,encoding):''}));return verify?result:output(result,signature);};return value;}
  cryptoModule.createSign=function(a){return signer(a,false);};cryptoModule.createVerify=function(a){return signer(a,true);};
  cryptoModule.sign=function(a,data,key){return cryptoModule.createSign(a).update(data).sign(key);};
  cryptoModule.verify=function(a,data,key,sig){return cryptoModule.createVerify(a).update(data).verify(key,sig);};
  cryptoModule.randomInt=function(min,max,callback){if(typeof max==='function'){callback=max;max=undefined;}var low=max===undefined?0:min,high=max===undefined?min:max,range=high-low;
    if(!Number.isSafeInteger(low)||!Number.isSafeInteger(high)||range<=0||range>281474976710655)throw new RangeError('Invalid randomInt range');
    function next(){var b=randomBytes(6),n=0;for(var i=0;i<6;i++)n=n*256+b[i];return n;}
    var limit=281474976710656-(281474976710656%range),n;do{n=next();}while(n>=limit);var result=low+n%range;
    if(callback){Promise.resolve().then(function(){callback(null,result);});return;}return result;};
  cryptoModule.randomFillSync=function(buffer,offset,size){var b=Buffer.isBuffer(buffer)?buffer._b:new Uint8Array(buffer.buffer||buffer,buffer.byteOffset||0,buffer.byteLength);offset=offset===undefined?0:offset;size=size===undefined?b.length-offset:size;
    if(!Number.isInteger(offset)||!Number.isInteger(size)||offset<0||size<0||offset+size>b.length)throw new RangeError('Invalid randomFill range');b.set(randomBytes(size)._b,offset);return buffer;};
  cryptoModule.randomFill=function(buffer,offset,size,cb){if(typeof offset==='function'){cb=offset;offset=undefined;size=undefined;}else if(typeof size==='function'){cb=size;size=undefined;}if(typeof cb!=='function')throw new TypeError('Callback required');Promise.resolve().then(function(){return cryptoModule.randomFillSync(buffer,offset,size);}).then(function(v){cb(null,v);},cb);};
  webcrypto.subtle.digest=function(a,data){return Promise.resolve().then(function(){return output(hostCrypto({operation:'digest',algorithm:typeof a==='string'?a:a.name,data:binary(data)}))._b.buffer;});};
''';
