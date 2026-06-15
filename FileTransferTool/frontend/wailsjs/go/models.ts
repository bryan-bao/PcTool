export namespace discovery {
	
	export class Peer {
	    name: string;
	    host: string;
	    port: number;
	
	    static createFrom(source: any = {}) {
	        return new Peer(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.host = source["host"];
	        this.port = source["port"];
	    }
	}

}

export namespace main {
	
	export class ShareState {
	    url: string;
	    tsUrl: string;
	    entries: server.ShareEntry[];
	
	    static createFrom(source: any = {}) {
	        return new ShareState(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.url = source["url"];
	        this.tsUrl = source["tsUrl"];
	        this.entries = this.convertValues(source["entries"], server.ShareEntry);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace server {
	
	export class ShareEntry {
	    id: string;
	    name: string;
	    isDir: boolean;
	    size: number;
	    count: number;
	
	    static createFrom(source: any = {}) {
	        return new ShareEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.isDir = source["isDir"];
	        this.size = source["size"];
	        this.count = source["count"];
	    }
	}

}

export namespace transfer {
	
	export class Task {
	    id: string;
	    name: string;
	    relPath: string;
	    totalBytes: number;
	    transferredBytes: number;
	    status: string;
	    direction: string;
	    peer: string;
	    limitBps: number;
	    speed: number;
	    etaSeconds: number;
	    err?: string;
	
	    static createFrom(source: any = {}) {
	        return new Task(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.relPath = source["relPath"];
	        this.totalBytes = source["totalBytes"];
	        this.transferredBytes = source["transferredBytes"];
	        this.status = source["status"];
	        this.direction = source["direction"];
	        this.peer = source["peer"];
	        this.limitBps = source["limitBps"];
	        this.speed = source["speed"];
	        this.etaSeconds = source["etaSeconds"];
	        this.err = source["err"];
	    }
	}

}

