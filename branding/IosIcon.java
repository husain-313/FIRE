import java.awt.*;
import java.awt.font.TextAttribute;
import java.awt.geom.*;
import java.awt.image.BufferedImage;
import java.io.File;
import java.util.HashMap;
import java.util.Map;
import javax.imageio.ImageIO;

// Draws the Fire logo set: an orange rounded mark with a white flame and a light, spaced
// capital wordmark, in the clean style of the Strong logo (vhplayer-mod/branding/Brand.java).
// Usage: java FireBrand.java <res dir> [font.ttf]
public class IosIcon {
    static final Color TOP = new Color(0xffa23d), BOTTOM = new Color(0xff4214);
    static Font light;

    public static void main(String[] a) throws Exception {
        int s = 1024;
        BufferedImage img = new BufferedImage(s, s, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = g(img);
        g.setPaint(new GradientPaint(0, 0, TOP, s, s, BOTTOM));
        g.fillRect(0, 0, s, s);
        mark(g, -s * 0.1f, -s * 0.1f, s * 1.2f);
        ImageIO.write(img, "png", new File(a[0]));
    }

    static void write(BufferedImage img, File res, String folder, String name) throws Exception {
        File d = new File(res, folder);
        d.mkdirs();
        ImageIO.write(img, "png", new File(d, name));
    }

    static BufferedImage banner(int k) {
        int w = 320 * k, h = 180 * k;
        BufferedImage b = canvas(w, h);
        Graphics2D g = g(b);
        g.setPaint(new GradientPaint(0, 0, new Color(0x2a160b), w, h, new Color(0x0b0807)));
        g.fillRect(0, 0, w, h);
        // A soft ember glow behind the mark.
        g.setPaint(new RadialGradientPaint(new Point2D.Float(w * 0.22f, h * 0.5f), w * 0.45f,
                new float[] {0f, 1f}, new Color[] {new Color(0xff, 0x6a, 0x1a, 85), new Color(0xff, 0x6a, 0x1a, 0)}));
        g.fillRect(0, 0, w, h);
        float s = 66 * k;
        mark(g, 46 * k, (h - s) / 2f, s);
        word(g, 46 * k + s + 22 * k, h / 2f, 60f * k);
        return b;
    }

    static BufferedImage trim(BufferedImage img) {
        int minX = img.getWidth(), maxX = -1;
        for (int x = 0; x < img.getWidth(); x++)
            for (int y = 0; y < img.getHeight(); y++)
                if ((img.getRGB(x, y) >>> 24) != 0) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); }
        if (maxX < 0) return img;
        int x0 = Math.max(0, minX - 4), x1 = Math.min(img.getWidth(), maxX + 5);
        return img.getSubimage(x0, 0, x1 - x0, img.getHeight());
    }

    static BufferedImage canvas(int w, int h) { return new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB); }

    static Graphics2D g(BufferedImage img) {
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON);
        g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
        g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
        return g;
    }

    static void mark(Graphics2D g, float x, float y, float s) {
        g.setPaint(new GradientPaint(x, y, TOP, x + s, y + s, BOTTOM));
        g.fill(new RoundRectangle2D.Float(x, y, s, s, s * 0.5f, s * 0.5f));
        // Outer flame, in a 0..1 box placed inside the square.
        float fx = x + s * 0.2f, fy = y + s * 0.14f, fs = s * 0.6f;
        g.setColor(Color.WHITE);
        g.fill(flame(fx, fy, fs, new float[][] {
                {0.50f, 0.00f},
                {0.66f, 0.22f, 0.92f, 0.38f, 0.90f, 0.66f},
                {0.88f, 0.90f, 0.70f, 1.00f, 0.50f, 1.00f},
                {0.28f, 1.00f, 0.10f, 0.88f, 0.10f, 0.66f},
                {0.10f, 0.48f, 0.22f, 0.38f, 0.30f, 0.28f},
                {0.32f, 0.40f, 0.38f, 0.48f, 0.45f, 0.50f},
                {0.40f, 0.32f, 0.42f, 0.14f, 0.50f, 0.00f}}));
        // Inner flame in the mark's own orange gives the fire its depth.
        g.setPaint(new GradientPaint(x, y + s * 0.5f, TOP, x, y + s, BOTTOM));
        g.fill(flame(fx, fy, fs, new float[][] {
                {0.52f, 0.50f},
                {0.62f, 0.62f, 0.72f, 0.70f, 0.70f, 0.82f},
                {0.68f, 0.93f, 0.60f, 0.97f, 0.50f, 0.97f},
                {0.39f, 0.97f, 0.30f, 0.90f, 0.31f, 0.80f},
                {0.32f, 0.70f, 0.40f, 0.66f, 0.45f, 0.60f},
                {0.47f, 0.66f, 0.50f, 0.70f, 0.53f, 0.70f},
                {0.50f, 0.62f, 0.49f, 0.56f, 0.52f, 0.50f}}));
    }

    static Path2D flame(float x, float y, float s, float[][] pts) {
        Path2D p = new Path2D.Float();
        p.moveTo(x + pts[0][0] * s, y + pts[0][1] * s);
        for (int i = 1; i < pts.length; i++) {
            float[] c = pts[i];
            p.curveTo(x + c[0] * s, y + c[1] * s, x + c[2] * s, y + c[3] * s, x + c[4] * s, y + c[5] * s);
        }
        p.closePath();
        return p;
    }

    static void word(Graphics2D g, float x, float centerY, float size) {
        Map<TextAttribute, Object> attrs = new HashMap<>();
        attrs.put(TextAttribute.SIZE, size);
        attrs.put(TextAttribute.TRACKING, 0.06f);
        g.setFont(light.deriveFont(attrs));
        FontMetrics m = g.getFontMetrics();
        // Capitals: centre on the cap height so the word sits level with the mark.
        float baseline = centerY + (m.getAscent() * 0.86f) / 2f;
        g.setColor(Color.WHITE);
        g.drawString("FIRE", x, baseline);
    }
}
