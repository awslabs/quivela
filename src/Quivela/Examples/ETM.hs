{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
module Quivela.Examples.ETM where

import Quivela

prove emptyVerifyEnv
  ([prog'|
method MacI(mac) {
    new (const mac=mac,tg=0) {
        method tag(m) { tg[m] = mac.tag(m) } ;
        method verify(m,t) { t & tg[m] == t }
    }
};

// _e freshly encrypts iff _e ~ Enc(_e)

method Enc(e) {
    new (const e=e, d=0) {
        method enc(m) { c = e.enc(m) & !d[c] & d[c] = m & c };
        method dec(c) { e.dec(c) }
    }
};


// _e is a CPA-secure encryptor iff CpaC(_e) ~ CpaI(_e)

method CpaC(e) {
    new (const e=e,h=0) {
        method enc(m) { c = e.enc(m) & h[c]=1 & c };
        method dec(c) { h[c] & e.dec(c) }
    }
};

method CpaI(e) {
    new (const e=e,d=0) {
        method enc(m) { c = e.enc(zero(m)) & d[c] = m & c };
        method dec(c) { d[c] }
    }
};

// _e is an AEAD encryptor iff _e ~ AeadI(_e)

method AeadI(e) {
    new (const e=e,d=0) {
        method enc(a,m) { c = e.enc(a,zero(m)) & d[<a,c>] = m & c };
        method dec(a,c) { d[<a,c>] }
    }
};


// concrete encrypt-then-mac

method EtM(e,mac) {
    new (const e=e, const mac=mac) {
        method enc(a,m) {
            m &
            em = e.enc(m) &
            t = mac.tag(<a,em>) &
            <em,t>
        };
        method dec(a,c) {
            em = c^0;
            t = c^1;
            c &
            mac.verify(<a,em>,t) &
            e.dec(em)
        }
    }
};

// zero a bit-string (`& 0` ensures zero-length strings remain zero-length)
method zero(m) { m & 0 };
_e = adversary() ;
_mac = adversary()
|])
  $ let mac_tg = fieldEqual ["mac", "tg"]
        cpa_d = fieldEqual ["cpa", "d"]
        d = fieldEqual ["d"]
        e_d = fieldEqual ["e", "d"]
        cpa_h = fieldEqual ["cpa", "h"]
  in
  [prog| EtM(_e,_mac) |]
  ≈
  [prog|
new (const e=_e,const mac=_mac) {
    method enc(a, m) {
        m &
        em = e.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        e.dec(em)
    }
}
|]
   ≈ Hint [rewrite "_mac" "MacI(_mac)"]:
   [prog|
new (const e=_e,const mac=MacI(_mac)) {
    method enc(a, m) {
        m &
        em = e.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        e.dec(em)
    }
}|]
   ≈ Hint [mac_tg]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=new(e=_e) {
        method enc(m) { e.enc(m) };
        method dec(c) { e.dec(c) }
    }) {
    method enc(a, m) {
        m &
        em = e.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        e.dec(em)
    }
} |]
   ≈ Hint [fieldEqual ["mac", "tg"]]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=new(const e=_e) {
        method enc(m) { e.enc(m) };
        method dec(c) { e.dec(c) }
    }) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
   ≈ Hint [fieldEqual ["mac", "tg"]]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=new(const e=_e,h=0) {
        method enc(m) { c = e.enc(m) & h[c] = 1 & c };
        method dec(c) { e.dec(c) }
    }) {
    method enc(a:*, m:*) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a:*, c:<*,*>) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
   ≈ Hint [ mac_tg, cpa_h, validLHS (getField ["mac", "tg"]), validLHS (getField ["cpa", "h"])
           , univInvariant [("a", TAny), ("em", TAny)] "!mac.tg[<a, em>] | cpa.h[em]"
           ]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=new(const e=_e,h=0) {
        method enc(m) { c = e.enc(m) & h[c] = 1 & c };
        method dec(c) { e.dec(c) }
    }) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.h[em] &
        cpa.dec(em)
    }
}|]
   ≈ Hint [ mac_tg, cpa_h, validLHS (getField ["cpa", "h"]) ]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=new(const e=_e,h=0) {
        method enc(m) { c = e.enc(m) & h[c] = 1 & c };
        method dec(c) { h[c] & e.dec(c) }
    }) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
   ≈ Hint [mac_tg, cpa_h]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=CpaC(_e)) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
   ≈ Hint [mac_tg, cpa_h]:
   [prog|
new (const mac=MacI(_mac),const cpa=CpaC(_e)) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
   ≈ Hint [rewrite "CpaC(_e)" "CpaI(_e)"]:
   [prog|
new (const mac=MacI(_mac),const cpa=CpaI(_e)) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
  ≈ Hint [mac_tg, cpa_d]:
  [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=CpaI(_e)) {
    method enc(a, m) {
        m &
        em = cpa.enc(m) &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.dec(em)
    }
}|]
  ≈ Hint [mac_tg, cpa_d]:
  [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=CpaI(_e)) {
    method enc(a, m) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        <em,t>
    };
    method dec(a, c) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.d[em]
    }
}|]
   ≈ Hint [mac_tg, cpa_d]: -- step 12:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=CpaI(_e),d=0) {
    method enc(a:*, m:*) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a:*, c:<*,*>) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.d[em]
    }
}|]
   ≈ Hint [rewrite "_e" "Enc(_e)"]:
   [prog|
new (const e=Enc(_e),const mac=MacI(_mac),const cpa=CpaI(Enc(_e)),d=0) {
    method enc(a:*,m:*) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a:*,c:<*,*>) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &
        cpa.d[em]
    }
}|]
   ≈ Hint [ mac_tg, e_d, cpa_d
      , validLHS (getField ["cpa", "d"])
      , validLHS (getField ["mac", "tg"])
      , univInvariant [ ("a", TAny), ("em", TAny), ("t", TAny) ]
        "d[<a, <em, t>>] == (t & (mac.tg[<a, em>] == t) & cpa.d[em])"
      , univInvariant [ ("a", TAny), ("em", TAny), ("t", TAny) ]
        "(!mac.tg[<a, em>]) | (cpa.d[em] & e.d[em])" ]:
     [prog|
new (const e=Enc(_e),const mac=MacI(_mac),const cpa=CpaI(Enc(_e)),d=0) {
    method enc(a:*,m:*) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a:*,c:<*,*>) {
        em = c^0;
        t = c^1;
        c &
        mac.verify(<a,em>,t) &  // t & mac.tg[<a,em>] == t
        cpa.d[em] &
        d[<a,<em,t>>]  // !d[<a,<em,t>>] | (t == mac.tg[<a,em>] & cpa.d[em] == d[<a,<em,t>>])
    }
}|]
   ≈ Hint [ mac_tg, e_d, d, cpa_d
           , validLHS (getField ["cpa", "d"])
           , validLHS (getField ["mac", "tg"])
           , univInvariant [ ("a", TAny), ("em", TAny), ("t", TAny) ] $
             "(!d[<a, <em, t>>]) | " ++
             "(t & ((t == mac.tg[<a, em>]) & (cpa.d[em] == d[<a, <em, t>>])) & e.d[em])" ]:
   [prog|
new (const e=Enc(_e),const mac=MacI(_mac),const cpa=CpaI(Enc(_e)),d=0) {
    method enc(a, m) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a, c) {
        d[<a,c>]
    }
}|]
   ≈ Hint [rewrite "Enc(_e)" "_e"]:
   [prog|
new (const e=_e,const mac=MacI(_mac),const cpa=CpaI(_e),d=0) {
    method enc(a, m) {
        m &
        em = e.enc(zero(m)) &
        cpa.d[em] = m &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a, c) {
        d[<a,c>]
    }
}|]
  ≈ Hint [mac_tg, validLHS (getField ["cpa", "d"]), d]:
  [prog|
new (const e=_e,const mac=MacI(_mac),d=0) {
    method enc(a, m) {
        m &
        em = e.enc(zero(m)) &
        em &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a, c) {
        d[<a,c>]
    }
}|]
  ≈ Hint [rewrite "MacI(_mac)" "_mac"]:
  [prog|
new (const e=_e,const mac=_mac,d=0) {
    method enc(a, m) {
        m &
        em = e.enc(zero(m)) &
        em &
        t = mac.tag(<a,em>) &
        d[<a,<em,t>>] = m &
        <em,t>
    };
    method dec(a, c) {
        d[<a,c>]
    }
}|]
  ≈ Hint [d]:
  [prog|
new (const e=new(const e=_e,const mac=_mac) {
        method enc(a, m) { m & em = e.enc(m) & em & t = mac.tag(<a,em>) & <em,t> };
        method dec(a, c) { em = c^0;  t = c^1;  mac.verify(<a, em>, t) & e.dec(em) }
    },d=0) {
    method enc(a, m) { c=e.enc(a, zero(m)) & d[<a,c>] = m & c };
    method dec(a, c) { d[<a,c>] }
}|]
   ≈ Hint [d]:
   [prog| AeadI(EtM(_e,_mac)) |]
   : []