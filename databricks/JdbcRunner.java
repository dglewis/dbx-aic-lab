import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

/**
 * Minimal SQL runner over the Databricks JDBC driver. Used for the phase-0
 * connectivity smoke test and for applying databricks/sql/*.sql DDL — no
 * connector involved, so failures isolate to network/auth/driver.
 *
 * Usage (driver jar on classpath, env from secrets/databricks.env):
 *   java -cp runtime/openidm/lib/databricks-jdbc-2.7.3.jar \
 *        databricks/JdbcRunner.java "SELECT 1" [@file.sql ...]
 *   java databricks/JdbcRunner.java --describe-auth   (no query; prints the
 *        auth method and redacted effective URL)
 *
 * Auth (ADR-002): OAuth M2M as the service principal when
 * DATABRICKS_SP_CLIENT_ID + DATABRICKS_SP_CLIENT_SECRET are set — same URL
 * assembly as idm-config/script/CustomizerScript.groovy; otherwise the
 * optional DATABRICKS_PAT.
 *
 * Statements in @files are split on ";" at end-of-line; comment-only lines
 * are dropped. Keep DDL comments on their own lines.
 */
public class JdbcRunner {

    public static void main(String[] args) throws Exception {
        String url = env("DATABRICKS_JDBC_URL");
        String clientId = env("DATABRICKS_SP_CLIENT_ID");
        String clientSecret = env("DATABRICKS_SP_CLIENT_SECRET");
        String pat = env("DATABRICKS_PAT");
        boolean m2m = clientId != null && clientSecret != null;
        if (url == null || (!m2m && pat == null)) {
            System.err.println("set DATABRICKS_JDBC_URL and either DATABRICKS_SP_CLIENT_ID + "
                    + "DATABRICKS_SP_CLIENT_SECRET (OAuth M2M, preferred) or DATABRICKS_PAT (optional)"
                    + " — source secrets/databricks.env");
            System.exit(2);
        }
        String effectiveUrl = m2m ? m2mUrl(url, clientId, clientSecret) : url;

        if (args.length == 1 && args[0].equals("--describe-auth")) {
            System.out.println("auth=" + (m2m ? "m2m" : "pat"));
            System.out.println("url=" + effectiveUrl
                    .replaceFirst("//[^:/;]+", "//<host>")
                    .replaceAll("(?i)(OAuth2Secret|PWD)=[^;]*", "$1=***"));
            return;
        }
        if (args.length == 0) {
            System.err.println("usage: JdbcRunner \"<sql>\" | @file.sql ...");
            System.exit(2);
        }

        List<String> statements = new ArrayList<>();
        for (String arg : args) {
            if (arg.startsWith("@")) {
                for (String chunk : Files.readString(Path.of(arg.substring(1))).split(";\\s*(\n|$)")) {
                    StringBuilder stmt = new StringBuilder();
                    for (String line : chunk.split("\n")) {
                        if (!line.strip().startsWith("--")) stmt.append(line).append('\n');
                    }
                    String s = stmt.toString().strip();
                    if (!s.isEmpty()) statements.add(s);
                }
            } else {
                statements.add(arg);
            }
        }

        // M2M: credentials are in the URL. PAT: AuthMech=3 URL, UID=token, PWD=<pat>.
        try (Connection conn = m2m
                ? DriverManager.getConnection(effectiveUrl)
                : DriverManager.getConnection(url, "token", pat);
             Statement st = conn.createStatement()) {
            for (String q : statements) {
                String head = q.replaceAll("\\s+", " ");
                System.out.println("== " + (head.length() > 90 ? head.substring(0, 90) + "…" : head));
                if (st.execute(q)) {
                    try (ResultSet rs = st.getResultSet()) {
                        ResultSetMetaData md = rs.getMetaData();
                        StringBuilder hdr = new StringBuilder("   ");
                        for (int i = 1; i <= md.getColumnCount(); i++) {
                            hdr.append(md.getColumnLabel(i)).append(i < md.getColumnCount() ? " | " : "");
                        }
                        System.out.println(hdr);
                        int rows = 0;
                        while (rs.next()) {
                            StringBuilder line = new StringBuilder("   ");
                            for (int i = 1; i <= md.getColumnCount(); i++) {
                                line.append(rs.getString(i)).append(i < md.getColumnCount() ? " | " : "");
                            }
                            System.out.println(line);
                            rows++;
                        }
                        System.out.println("   (" + rows + " rows)");
                    }
                } else {
                    System.out.println("   ok (updateCount=" + st.getUpdateCount() + ")");
                }
            }
        }
        System.out.println("SMOKE-OK");
    }

    private static String env(String key) {
        String v = System.getenv(key);
        return v == null || v.isBlank() ? null : v;
    }

    /** Strip any auth params and append OAuth M2M ones (mirrors CustomizerScript.groovy). */
    static String m2mUrl(String url, String clientId, String clientSecret) {
        StringBuilder kept = new StringBuilder();
        for (String part : url.split(";")) {
            if (part.matches("(?i)(AuthMech|Auth_Flow|OAuth2ClientId|OAuth2Secret|UID|PWD)=.*")) continue;
            if (kept.length() > 0) kept.append(';');
            kept.append(part);
        }
        return kept + ";AuthMech=11;Auth_Flow=1;OAuth2ClientId=" + clientId + ";OAuth2Secret=" + clientSecret;
    }
}
