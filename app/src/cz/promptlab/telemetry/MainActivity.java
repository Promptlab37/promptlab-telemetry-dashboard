package cz.promptlab.telemetry;

import android.app.Activity;
import android.app.KeyguardManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * Minimalni prohlizec na jedinou stranku: dashboard telemetrie.
 *
 * Proc vlastni aplikace a ne Chrome:
 *   - Chrome neprepne stranku na celou obrazovku bez gesta uzivatele
 *     a MIUI blokuje injektaz vstupu pres adb, takze to klepnuti nejde
 *     udelat ani zvenci.
 *   - Stranka v prohlizeci navic NEDOKAZE rozsvitit displej. Aktivita to
 *     pres setTurnScreenOn() dokaze a nepotrebuje k tomu zadne opravneni.
 *
 * Rezim spanku displeje:
 *   Stranka pres JS most (window.PL.setAwake) rekne, jestli ma displej
 *   svitit. Kdyz uzivatel dlouho neni u pocitace, zavola setAwake(false),
 *   aktivita pusti FLAG_KEEP_SCREEN_ON a displej zhasne podle timeoutu.
 *   Navrat resi pocitac: hlidac spusti aktivitu pres "am start" a ta diky
 *   setTurnScreenOn() displej rozsviti.
 *
 * Pozn.: trida zamerne NEOBSAHUJE anonymni vnitrni tridy - d8 na nich
 * pri kompilaci s -source 8 padal na internal error. Proto je Runnable
 * implementovan primo na aktivite.
 */
public class MainActivity extends Activity implements Runnable {

    private static final String URL = "http://localhost:8099/";

    private WebView web;
    private Handler ui;
    private volatile boolean wantAwake = true;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        ui = new Handler(Looper.getMainLooper());

        // Klicove: aktivita smi displej ROZSVITIT a ukazat se i pres zamek.
        if (Build.VERSION.SDK_INT >= 27) {
            setTurnScreenOn(true);
            setShowWhenLocked(true);
            KeyguardManager km = (KeyguardManager) getSystemService(KEYGUARD_SERVICE);
            if (km != null) {
                km.requestDismissKeyguard(this, null);
            }
        } else {
            getWindow().addFlags(
                  WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD);
        }

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Kreslit i pod vyrezem, at je vyuzita cela plocha.
        if (Build.VERSION.SDK_INT >= 28) {
            getWindow().getAttributes().layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setMediaPlaybackRequiresUserGesture(false);
        // Aplikaci spousti hlidac hned po prihlaseni, jeste nez nabehne
        // server na pocitaci. RetryClient stranku dotahne, az bude k mani.
        web.setWebViewClient(new RetryClient(web, URL));
        web.setBackgroundColor(0xFF000000);
        web.addJavascriptInterface(this, "PL");   // most pro stranku

        setContentView(web);
        web.loadUrl(URL);

        hideSystemBars();
    }

    /* ---------- most pro stranku ---------- */

    /** Stranka rika, jestli ma displej dal svitit. */
    @JavascriptInterface
    public void setAwake(boolean awake) {
        wantAwake = awake;
        ui.post(this);
    }

    /** Aby si stranka mohla overit, ze bezi uvnitr teto aplikace. */
    @JavascriptInterface
    public boolean isNativeApp() {
        return true;
    }

    /* ---------- UI ---------- */

    /** Skryje stavovy i navigacni pruh (immersive sticky). */
    private void hideSystemBars() {
        View d = getWindow().getDecorView();
        d.setSystemUiVisibility(
              View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    /** Bezi na UI vlakne: srovna pruhy i priznak sviceni displeje. */
    @Override
    public void run() {
        hideSystemBars();
        if (wantAwake) {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else {
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        }
    }

    @Override
    public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused) {
            hideSystemBars();
            ui.postDelayed(this, 600);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        wantAwake = true;                 // po probuzeni vzdy sviti
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        hideSystemBars();
        if (web != null) {
            web.reload();                 // po navratu vzdy cerstva data
        }
    }

    /** Tlacitkem Zpet aplikaci nezavirat - je to trvaly displej. */
    @Override
    public void onBackPressed() {
        // zamerne prazdne
    }
}
