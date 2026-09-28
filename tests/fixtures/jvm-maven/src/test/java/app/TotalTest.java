package app;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;
class TotalTest { @Test void adds(){ assertEquals(42, Total.of(new int[]{1,2,39})); } }
