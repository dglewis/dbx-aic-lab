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
 *
 * Statements in @files are split on ";" at end-of-line; comment-only lines
 * are dropped. Keep DDL comments on their own lines.
 */
public class JdbcRunner {

    public static void main(String[] args) throws Exception {
        String url = System.getenv("DATABRICKS_JDBC_URL");
        String pat = System.getenv("DATABRICKS_PAT");
        if (url == null || url.isBlank() || pat == null || pat.isBlank()) {
            System.err.println("DATABRICKS_JDBC_URL / DATABRICKS_PAT not set — source secrets/databricks.env");
            System.exit(2);
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

        // PAT auth: AuthMech=3 in the URL, UID=token, PWD=<pat> as credentials
        try (Connection conn = DriverManager.getConnection(url, "token", pat);
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
}
