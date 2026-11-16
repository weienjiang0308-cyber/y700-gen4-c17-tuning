// 动态改值小工具：调用系统 OverlayManager 的 fabricated overlay 接口，支持任意资源类型（包括尺寸 dimen）。
// 系统自带的 `cmd overlay fabricate` 只接受整数/颜色类型，改不了尺寸，所以写了这个。
// 一次可以写多个资源，一次提交、一次生效（避免界面出现改了一半的中间状态）。
// 全部用反射，不依赖任何编译期 SDK。必须以 root 运行：
//   CLASSPATH=/path/fab.dex app_process /system/bin Fab <名称> <目标包> <配置|-> <资源> <类型> <值> [<资源> <类型> <值> ...]
//   例：Fab y700_vol com.android.systemui - com.android.systemui:dimen/xxx 5 0x1001
//   配置写 port / land 表示只在竖屏 / 横屏生效，写 - 表示都生效
// 类型：5 = 尺寸（值 = (数值<<8)|单位，单位 1 = dp），16 = 整数，28 = 颜色
// 加 --enable 作为第一个参数：提交后顺便启用
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

public class Fab {
    public static void main(String[] args) throws Throwable {
        List<String> a = new ArrayList<>();
        boolean enable = false;
        for (String s : args) { if (s.equals("--enable")) enable = true; else a.add(s); }
        if (a.size() < 6 || (a.size() - 3) % 3 != 0) {
            System.err.println("用法: Fab [--enable] 名称 目标包 配置|- 资源 类型 值 [资源 类型 值 ...]");
            System.exit(2);
        }
        String name = a.get(0), target = a.get(1);
        String config = a.get(2).equals("-") ? null : a.get(2);

        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object binder = sm.getMethod("getService", String.class).invoke(null, "overlay");
        if (binder == null) { System.err.println("overlay 服务还没启动"); System.exit(3); }
        Class<?> ibinder = Class.forName("android.os.IBinder");
        Object om = Class.forName("android.content.om.IOverlayManager$Stub")
                .getMethod("asInterface", ibinder).invoke(null, binder);

        Class<?> fb = Class.forName("android.content.om.FabricatedOverlay$Builder");
        Constructor<?> c = fb.getConstructor(String.class, String.class, String.class);
        Object b = c.newInstance("com.android.shell", name, target);
        Method set4 = null;
        for (Method m : fb.getMethods()) {
            Class<?>[] p = m.getParameterTypes();
            if (m.getName().equals("setResourceValue") && p.length == 4
                    && p[0] == String.class && p[1] == int.class && p[2] == int.class && p[3] == String.class) {
                set4 = m;
            }
        }
        // 系统接口只放行整数/颜色类型（16~31）：先当整数加进去，build 之后再把记录里的类型改回真正的类型
        List<String> patchRes = new ArrayList<>();
        List<Integer> patchType = new ArrayList<>();
        for (int i = 3; i < a.size(); i += 3) {
            String res = a.get(i);
            int type = Integer.decode(a.get(i + 1));
            int value = (int) Long.decode(a.get(i + 2)).longValue();
            boolean patch = type < 16 || type > 31;
            int t0 = patch ? 16 : type;
            if (set4 != null) set4.invoke(b, res, t0, value, config);
            else fb.getMethod("setResourceValue", String.class, int.class, int.class).invoke(b, res, t0, value);
            if (patch) { patchRes.add(res); patchType.add(type); }
        }
        Object fo = fb.getMethod("build").invoke(b);
        if (!patchRes.isEmpty()) {
            int n = 0;
            for (Field f : fo.getClass().getDeclaredFields()) {
                if (!f.getType().getName().endsWith("FabricatedOverlayInternal")) continue;
                f.setAccessible(true);
                Object internal = f.get(fo);
                Field ef = internal.getClass().getField("entries");
                for (Object e : (List<?>) ef.get(internal)) {
                    int idx = patchRes.indexOf((String) e.getClass().getField("resourceName").get(e));
                    if (idx >= 0) { e.getClass().getField("dataType").setInt(e, patchType.get(idx)); n++; }
                }
            }
            if (n < patchRes.size()) throw new IllegalStateException("有资源记录没找到，没法改类型");
        }

        Class<?> foc = Class.forName("android.content.om.FabricatedOverlay");
        Class<?> tbc = Class.forName("android.content.om.OverlayManagerTransaction$Builder");
        Object tb = tbc.getConstructor().newInstance();
        tbc.getMethod("registerFabricatedOverlay", foc).invoke(tb, fo);
        if (enable) {
            Class<?> oid = Class.forName("android.content.om.OverlayIdentifier");
            Object id = oid.getConstructor(String.class, String.class).newInstance("com.android.shell", name);
            tbc.getMethod("setEnabled", oid, boolean.class).invoke(tb, id, true);
        }
        Object tx = tbc.getMethod("build").invoke(tb);
        Class<?> txc = Class.forName("android.content.om.OverlayManagerTransaction");
        om.getClass().getMethod("commit", txc).invoke(om, tx);
        System.out.println("已创建 com.android.shell:" + name + (enable ? "（已启用）" : ""));
    }
}
