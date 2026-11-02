import Foundation

/// Runs in WKContentWorld.page so focus, DOM mutations, and site handlers are real page state.
/// Script-created events are untrusted; protected user-activation APIs may refuse them.
enum BrowserDOMScript {
    static func command(_ action: BrowserAction) throws -> String {
        let payload = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        return "(function(cmd) {\n" + implementation + "\n})(" + payload + ")"
    }

    private static let implementation = #"""
    const fail = (code, message) => JSON.stringify({ok:false, error:{code,message}, trusted:false});
    const done = value => JSON.stringify({ok:true, trusted:false, ...value});
    const describe = el => ({tag:el.tagName?.toLowerCase(), id:el.id || null, type:el.type || null});
    const isTextInput = el => el instanceof el.ownerDocument.defaultView.HTMLTextAreaElement ||
        (el instanceof el.ownerDocument.defaultView.HTMLInputElement &&
         ['text','search','url','tel','password','email','number'].includes(el.type));
    function active(doc = document) {
        let el = doc.activeElement;
        while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
        if (el?.tagName === 'IFRAME' || el?.tagName === 'FRAME') {
            try { if (!el.contentDocument) throw Error(); return active(el.contentDocument); }
            catch { throw {code:'cross_origin_frame', message:'Focused frame is cross-origin; DOM input cannot access its document.'}; }
        }
        return el;
    }
    function atPoint(doc, x, y) {
        let el = doc.elementFromPoint(x,y);
        if (!el) throw {code:'no_hit_target', message:'No DOM element exists at these viewport coordinates.'};
        while (el.shadowRoot?.elementFromPoint) {
            const inner = el.shadowRoot.elementFromPoint(x,y);
            if (!inner || inner === el) break;
            el = inner;
        }
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
            try {
                if (!el.contentDocument) throw Error();
                const r = el.getBoundingClientRect();
                const sx = el.offsetWidth ? r.width / el.offsetWidth : 1;
                const sy = el.offsetHeight ? r.height / el.offsetHeight : 1;
                return atPoint(el.contentDocument, (x-r.left)/sx-el.clientLeft, (y-r.top)/sy-el.clientTop);
            } catch (error) {
                if (error.code) throw error;
                throw {code:'cross_origin_frame', message:'Click hit a cross-origin frame; synthetic DOM input cannot access it.'};
            }
        }
        return {el,x,y};
    }
    function insert(el, text, inputType = 'insertText') {
        if (!el || (!isTextInput(el) && !el.isContentEditable))
            throw {code:'no_editable_focus', message:'Focus an editable input, textarea, or contenteditable element before typing.'};
        if (el.disabled || el.readOnly)
            throw {code:'not_editable', message:'Focused element is disabled or read-only.'};
        const w = el.ownerDocument.defaultView;
        if (!el.dispatchEvent(new w.InputEvent('beforeinput', {bubbles:true,cancelable:true,inputType,data:text})))
            return {applied:false, canceled:true, target:describe(el)};
        if (isTextInput(el)) {
            if (el.selectionStart === null)
                throw {code:'unsupported_input_type', message:'Focused input type does not expose an editable selection; use its native control.'};
            const start = el.selectionStart, end = el.selectionEnd;
            const setter = Object.getOwnPropertyDescriptor(el.tagName === 'TEXTAREA' ? w.HTMLTextAreaElement.prototype : w.HTMLInputElement.prototype, 'value').set;
            setter.call(el, el.value.slice(0,start) + text + el.value.slice(end));
            el.setSelectionRange(start + text.length, start + text.length);
            el.dispatchEvent(new w.InputEvent('input', {bubbles:true,inputType,data:text}));
        } else {
            // execCommand preserves the document's selection and editing undo behavior.
            if (!el.ownerDocument.execCommand('insertText',false,text))
                throw {code:'editing_failed', message:'WebKit refused insertion into the focused contenteditable selection.'};
        }
        return {applied:true, target:describe(el), characters:text.length};
    }
    try {
        if (cmd.action === 'click') {
            if (!Number.isFinite(cmd.x) || !Number.isFinite(cmd.y) || cmd.x < 0 || cmd.y < 0 || cmd.x >= innerWidth || cmd.y >= innerHeight)
                return fail('coordinates_out_of_bounds','Click coordinates must lie inside the top-left CSS-pixel viewport.');
            const {el,x,y} = atPoint(document,cmd.x,cmd.y), w = el.ownerDocument.defaultView;
            if (el.disabled || el.closest('[inert]')) return fail('target_disabled','Click target is disabled or inert.');
            const init = {bubbles:true,cancelable:true,composed:true,view:w,clientX:x,clientY:y,button:0};
            el.dispatchEvent(new w.PointerEvent('pointerover',{...init,pointerId:1,pointerType:'mouse',isPrimary:true}));
            el.dispatchEvent(new w.MouseEvent('mouseover',init));
            const pointerAllowed = el.dispatchEvent(new w.PointerEvent('pointerdown',{...init,buttons:1,pointerId:1,pointerType:'mouse',isPrimary:true}));
            const mouseAllowed = pointerAllowed && el.dispatchEvent(new w.MouseEvent('mousedown',{...init,buttons:1}));
            if (mouseAllowed) (el.closest('input,textarea,button,select,a[href],[tabindex],[contenteditable]') || el).focus?.({preventScroll:true});
            el.dispatchEvent(new w.PointerEvent('pointerup',{...init,pointerId:1,pointerType:'mouse',isPrimary:true}));
            if (pointerAllowed) el.dispatchEvent(new w.MouseEvent('mouseup',init));
            const accepted = el.dispatchEvent(new w.MouseEvent('click',init));
            return done({target:describe(el),x:cmd.x,y:cmd.y,canceled:!accepted,notice:'Synthetic DOM click; no trusted user activation.'});
        }
        if (cmd.action === 'scroll') {
            if (!Number.isFinite(cmd.delta_x) || !Number.isFinite(cmd.delta_y)) return fail('invalid_delta','Scroll deltas must be finite CSS pixels.');
            let el = active();
            while (el && el !== el.ownerDocument.scrollingElement) {
                const style = el.ownerDocument.defaultView.getComputedStyle(el);
                if ((/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight) ||
                    (/(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth)) break;
                el = el.parentElement || el.getRootNode().host;
            }
            el = el || document.scrollingElement;
            if (!el) return fail('no_scroll_target','Document has no scrolling element.');
            const before = {x:el.scrollLeft,y:el.scrollTop};
            el.scrollBy({left:cmd.delta_x,top:cmd.delta_y,behavior:'instant'});
            return done({target:describe(el),before,after:{x:el.scrollLeft,y:el.scrollTop},applied_delta_x:el.scrollLeft-before.x,applied_delta_y:el.scrollTop-before.y});
        }
        if (cmd.action === 'type') return done(insert(active(),cmd.text));
        if (cmd.action === 'key') {
            const aliases = {Return:'Enter',Esc:'Escape',Space:' ',Spacebar:' ',Left:'ArrowLeft',Right:'ArrowRight',Up:'ArrowUp',Down:'ArrowDown'};
            let key = aliases[cmd.key] || cmd.key;
            const selectAll = /^(Meta|Command|Control|Ctrl)\+a$/i.test(key);
            if (selectAll) key = 'a';
            const supported = ['Enter','Tab','Backspace','Delete','Escape','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'];
            if (!selectAll && !supported.includes(key) && Array.from(key).length !== 1)
                return fail('unsupported_key','Supported keys: Enter, Tab, Backspace, Delete, Escape, arrows, Home, End, PageUp, PageDown, single characters, and Command/Control+A. Other shortcuts require native trusted input.');
            const el = active() || document.body, doc = el.ownerDocument, w = doc.defaultView;
            const init = {key,bubbles:true,cancelable:true,composed:true,metaKey:selectAll && !/^(Control|Ctrl)/i.test(cmd.key),ctrlKey:selectAll && /^(Control|Ctrl)/i.test(cmd.key)};
            const allowed = el.dispatchEvent(new w.KeyboardEvent('keydown',init));
            let effect = allowed ? 'event_only' : 'canceled';
            if (allowed) {
                if (selectAll && isTextInput(el) && el.selectionStart !== null) { el.select(); effect = 'selected_all'; }
                else if (selectAll && el.isContentEditable) { const r=doc.createRange();r.selectNodeContents(el);const s=w.getSelection();s.removeAllRanges();s.addRange(r);effect='selected_all'; }
                else if (key === 'Tab') {
                    const candidates = [...doc.querySelectorAll('a[href],button,input,select,textarea,[tabindex],[contenteditable="true"]')].filter(e => !e.disabled && !e.closest('[inert]') && e.tabIndex >= 0 && e.getClientRects().length);
                    if (!candidates.length) return fail('no_focus_target','Document has no eligible tab focus target.');
                    candidates.sort((a,b) => (a.tabIndex || Infinity)-(b.tabIndex || Infinity));
                    candidates[(candidates.indexOf(el)+1)%candidates.length].focus(); effect='focus_next';
                } else if ((key === 'Backspace' || key === 'Delete') && isTextInput(el)) {
                    if (el.selectionStart === null) return fail('unsupported_input_type','Input type does not expose selection.');
                    if (el.disabled || el.readOnly) return fail('not_editable','Focused element is disabled or read-only.');
                    const start=el.selectionStart,end=el.selectionEnd;
                    if (start === end) {
                        const n=key==='Backspace' ? (Array.from(el.value.slice(0,start)).pop()?.length || 0) : (Array.from(el.value.slice(end))[0]?.length || 0);
                        el.setSelectionRange(key==='Backspace'?start-n:start,key==='Delete'?end+n:end);
                    }
                    const result=insert(el,'',key==='Backspace'?'deleteContentBackward':'deleteContentForward');effect=result.applied?'deleted':'canceled';
                } else if ((key === 'Backspace' || key === 'Delete') && el.isContentEditable) {
                    effect=doc.execCommand(key==='Backspace'?'delete':'forwardDelete')?'deleted':'event_only';
                } else if (['ArrowLeft','ArrowRight','Home','End'].includes(key) && isTextInput(el) && el.selectionStart !== null) {
                    const p=key==='Home'?0:key==='End'?el.value.length:key==='ArrowLeft'?Math.max(0,el.selectionStart-1):Math.min(el.value.length,el.selectionEnd+1);
                    el.setSelectionRange(p,p);effect='moved_caret';
                } else if (key === 'Enter' && el.tagName === 'TEXTAREA') { const r=insert(el,'\n','insertLineBreak');effect=r.applied?'inserted_line_break':'canceled'; }
                else if (key === 'Enter' && el.isContentEditable) { effect=doc.execCommand('insertParagraph')?'inserted_paragraph':'event_only'; }
                else if (key === 'Enter' && el.form) {
                    const submitter=el.form.querySelector('button[type="submit"],button:not([type]),input[type="submit"]');
                    if (submitter && !submitter.disabled) el.form.requestSubmit(submitter); else el.form.requestSubmit();
                    effect='requested_form_submit';
                } else if ((key === 'Enter' || key === ' ') && el.matches('button,a[href],input[type="button"],input[type="submit"],input[type="checkbox"],input[type="radio"]')) { el.click();effect='activated'; }
                else if (Array.from(key).length === 1 && !selectAll) { const r=insert(el,key);effect=r.applied?'inserted_text':'canceled'; }
                else if (['ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(key) && !isTextInput(el) && !el.isContentEditable) {
                    const s=doc.scrollingElement;
                    if (s) { if(key==='Home'||key==='End')s.scrollTo({top:key==='Home'?0:s.scrollHeight,behavior:'instant'});else s.scrollBy({top:(key.includes('Up')?-1:1)*(key.startsWith('Page')?w.innerHeight:40),behavior:'instant'});effect='scrolled'; }
                }
            }
            el.dispatchEvent(new w.KeyboardEvent('keyup',init));
            return done({key,effect,target:describe(el),notice:'Synthetic DOM key events; supported default behaviors are explicitly simulated. OS shortcuts and user activation are unavailable.'});
        }
        return fail('unsupported_action','This command is not a DOM input action.');
    } catch (error) { return fail(error.code || 'dom_error',error.message || String(error)); }
    """#
}
